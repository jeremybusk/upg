-- +goose Down
SET search_path = monitor, public;

-- Remove cron jobs (ignore if missing)
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname IN ('monitor-due-runner','monitor-retention-sweeper');

DROP VIEW IF EXISTS v_monitor_failures_24h;
DROP VIEW IF EXISTS v_monitor_latest;

DROP FUNCTION IF EXISTS sweep_per_monitor_retention();
DROP FUNCTION IF EXISTS run_due_monitors();
DROP FUNCTION IF EXISTS run_monitor_once(bigint);
DROP FUNCTION IF EXISTS add_monitor(monitor_kind, text, text, interval, interval);
DROP FUNCTION IF EXISTS prom_label(text,text,text);
DROP FUNCTION IF EXISTS prom_int(text,text);
DROP FUNCTION IF EXISTS prom_value(text,text);

DROP TABLE IF EXISTS silences;
DROP TABLE IF EXISTS monitor_results;
DROP TABLE IF EXISTS monitors;
DROP TABLE IF EXISTS settings;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'monitor_kind') THEN
    DROP TYPE monitor_kind;
  END IF;
END$$;

-- Keep schema; drop if you want complete cleanup:
-- DROP SCHEMA IF EXISTS monitor CASCADE;

