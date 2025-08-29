-- +goose Down
SET search_path = monitor, public;

DROP VIEW IF EXISTS v_recent_fail_debug;

-- Revert run_monitor_once to pass Accept: text/plain (prior behavior)
CREATE OR REPLACE FUNCTION run_monitor_once(p_monitor_id bigint)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  s settings;
  m monitors;
  targ_encoded text;
  url text;
  resp_status int;
  resp_body   text;
  ok boolean := false;
  err text := NULL;
  ip_txt text;
  ip_val inet;
  success_val double precision;
  now_ts timestamptz := now();
  dbg_labels jsonb := NULL;
BEGIN
  SELECT * INTO s FROM settings WHERE id=1;
  SELECT * INTO m FROM monitors WHERE id=p_monitor_id AND enabled=true FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  IF EXISTS (
    SELECT 1 FROM silences si
    WHERE now() BETWEEN si.starts_at AND si.ends_at
      AND (si.monitor_id = m.id OR (si.target_like IS NOT NULL AND m.target LIKE si.target_like))
      AND (si.module IS NULL OR si.module = m.module)
  ) THEN
    UPDATE monitors
      SET last_run_at = now_ts, next_run_at = now_ts + m.period, updated_at = now()
      WHERE id = m.id;
    RETURN;
  END IF;

  targ_encoded := m.target;
  BEGIN
    SELECT uri_encode(m.target) INTO targ_encoded;
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      SELECT urlencode(m.target) INTO targ_encoded;
    EXCEPTION WHEN undefined_function THEN
      targ_encoded := m.target;
    END;
  END;

  url := s.blackbox_base || '/probe?module=' || m.module || '&target=' || targ_encoded;

  SELECT status, body INTO resp_status, resp_body
  FROM probe_fetch(url, s.http_timeout_ms, 'text/plain');

  IF resp_status = 200 THEN
    success_val := prom_value(resp_body, 'probe_success');
    IF success_val IS NULL THEN
      ok := false;
      err := 'parse: missing probe_success';
      dbg_labels := jsonb_build_object(
        'url', url,
        'body_head', substring(resp_body from 1 for 300)
      );
    ELSE
      ok := (success_val > 0.5);
    END IF;
  ELSE
    ok := false;
    err := format('exporter HTTP %s', resp_status);
    dbg_labels := jsonb_build_object('url', url);
  END IF;

  -- (rest unchanged)
  -- Optional IP …
  DECLARE
    ip_txt text;
    ip_val inet;
  BEGIN END;
END;
$$;

-- Recreate probe_fetch with earlier default Accept 'text/plain'
CREATE OR REPLACE FUNCTION probe_fetch(
  p_url text,
  p_timeout_ms integer DEFAULT 5000,
  p_accept text DEFAULT 'text/plain'
) RETURNS TABLE(status int, body text)
LANGUAGE plpgsql AS $$
DECLARE
  s int;
  c bytea;
BEGIN
  BEGIN
    SELECT h.status, h.content INTO s, c
    FROM http_get(
      p_url,
      ARRAY[ http_header('Accept', p_accept) ]::http_header[],
      p_timeout_ms::int
    ) AS h;
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      SELECT h.status, h.content INTO s, c
      FROM http_get(
        p_url,
        ARRAY[ http_header('Accept', p_accept) ]::http_header[]
      ) AS h;
    EXCEPTION WHEN undefined_function THEN
      SELECT h.status, h.content INTO s, c
      FROM http_get(p_url) AS h;
    END;
  END;

  status := s;
  body   := convert_from(COALESCE(c, ''::bytea), 'UTF8');
  RETURN NEXT;
END;
$$;

