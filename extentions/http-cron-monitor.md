# http cron monitor example

## CNPG yaml

```
spec:
  postgresql:
    shared_preload_libraries:
      - pg_cron
    parameters:
      cron.database_name: "sdx"            # <-- jobs run in DB 'sdx'
      cron.use_background_workers: "on"     # <-- no external connection needed
```

## Functions/Table

```
-- 0) PRE-REQ (outside this SQL if you're on CNPG):
--    - Your image must include both extensions (e.g. Debian packages: postgresql-17-cron, postgresql-17-http)
--    - In your CNPG Cluster manifest, set:
--        spec.postgresql.shared_preload_libraries: ["pg_cron"]
--        spec.postgresql.parameters.cron.database_name: "app"   -- match the DB below
--    Do NOT use ALTER SYSTEM in CNPG; the operator manages postgresql.auto.conf.

BEGIN;

-- 1) Work inside the same DB that pg_cron will use.
--    If cron.database_name is "app", be sure you're connected to "app"
--    when you run these CREATE EXTENSION statements.
CREATE EXTENSION IF NOT EXISTS http;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 2) Objects
CREATE TABLE IF NOT EXISTS public.http_responses (
    id BIGSERIAL PRIMARY KEY,           -- identity would also be fine
    url TEXT NOT NULL,
    response_status INT,
    response_content TEXT,
    fetched_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3) Safer function:
--    - Handles NULL content / NULL regex: use COALESCE + !~ instead of "NOT ... ~ ..."
--    - Schema-qualify everything, so cron doesn’t depend on search_path.
--    - EXCEPTION safety: if http_get throws, record it instead of failing the job.
CREATE OR REPLACE FUNCTION public.monitor_http_url(
    p_url TEXT,
    p_expected_status INT,
    p_content_regex TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_resp public.http_response;
    v_message TEXT;
    v_content TEXT;
    v_status INT;
BEGIN
    BEGIN
        -- http_get returns a composite http_response (status, content, headers)
        SELECT http_get(p_url) INTO v_resp;
        v_status  := v_resp.status;
        v_content := v_resp.content;
    EXCEPTION
        WHEN OTHERS THEN
            v_status  := NULL;
            v_content := format('http_get error: %s', SQLERRM);
    END;

    INSERT INTO public.http_responses (url, response_status, response_content)
    VALUES (p_url, v_status, v_content);

    -- Fire alert if status mismatches OR content regex doesn’t match (with NULL safety)
    IF (v_status IS DISTINCT FROM p_expected_status)
       OR (p_content_regex IS NOT NULL AND COALESCE(v_content, '') !~ p_content_regex)
    THEN
        v_message := format(
            'HTTP Monitor Alert: URL %s returned status %s (expected %s) or content did not match regex. Content snippet: %s',
            p_url, COALESCE(v_status::text,'<NULL>'), p_expected_status,
            left(COALESCE(v_content,''), 100)
        );
        PERFORM pg_notify('http_monitor_channel', v_message);
    END IF;
END;
$$;

-- 4) DO NOT use ALTER SYSTEM in CNPG. Set this via the cluster manifest instead.
--    If you're NOT on CNPG and insist on ALTER SYSTEM, do it as superuser and restart.
-- ALTER SYSTEM SET cron.use_background_workers = on;

-- 5) Schedules
--    - Use schema-qualified function call.
--    - Make sure cron.database_name points to THIS database (e.g., "app") so the function/table exist.
SELECT cron.schedule(
    'http-monitor',
    '*/1 * * * *',
    $$SELECT public.monitor_http_url('http://example.com', 200, '.*Example.*')$$
);

SELECT cron.schedule(
    'http-cleanup',
    '*/2 * * * *',
    $$DELETE FROM public.http_responses WHERE fetched_at < NOW() - INTERVAL '1 day'$$
);

COMMIT;

-- In another session to see alerts:
-- LISTEN http_monitor_channel;

```

## Create Extensions

```
SHOW shared_preload_libraries;          -- should include pg_cron
SHOW cron.use_background_workers;       -- should be on
SHOW cron.database_name;                -- should be sdx

-- Make sure extensions & objects exist in *sdx*
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS http;

-- Recreate the jobs (schema-qualify to avoid search_path surprises)
SELECT cron.unschedule('http-monitor')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='http-monitor');
SELECT cron.unschedule('http-cleanup')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='http-cleanup');

SELECT cron.schedule(
  'http-monitor',
  '*/1 * * * *',
  $$SELECT public.monitor_http_url('http://example.com', 200, '.*Example.*')$$
);

SELECT cron.schedule(
  'http-cleanup',
  '*/2 * * * *',
  $$DELETE FROM public.http_responses WHERE fetched_at < NOW() - INTERVAL '1 day'$$
);

```


## Quick Job Health Checks

```
-- See current/last runs
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY runid DESC
LIMIT 20;

-- Confirm jobs registered where you think they are
SELECT jobid, jobname, database, username, schedule, command
FROM cron.job
ORDER BY jobid;

```
