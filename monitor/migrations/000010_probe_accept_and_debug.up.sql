-- +goose Up
SET search_path = monitor, public;

-- 1) probe_fetch: allow NULL p_accept to send *no* headers; default to plain text
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
  IF p_accept IS NULL THEN
    -- No headers at all
    BEGIN
      SELECT h.status, h.content INTO s, c
      FROM http_get(p_url, p_timeout_ms::int) AS h;   -- some builds support (url, timeout)
    EXCEPTION WHEN undefined_function THEN
      SELECT h.status, h.content INTO s, c
      FROM http_get(p_url) AS h;
    END;
  ELSE
    -- Send a single Accept header
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
  END IF;

  status := s;
  body   := convert_from(COALESCE(c, ''::bytea), 'UTF8');
  RETURN NEXT;
END;
$$;

-- 2) run_monitor_once: call probe_fetch with NULL accept (no header)
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

  -- Encode target if available
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

  -- No Accept header (NULL): exporter will use its default exposition
  SELECT status, body INTO resp_status, resp_body
  FROM probe_fetch(url, s.http_timeout_ms, NULL);

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

  -- Optional IP
  ip_txt := COALESCE(
    prom_label(resp_body, 'probe_http_ssl', 'ip'),
    prom_label(resp_body, 'probe_dns_lookup_time_seconds', 'ip'),
    prom_label(resp_body, 'probe_ip_connect_time_seconds', 'ip')
  );
  BEGIN
    IF ip_txt IS NOT NULL THEN ip_val := ip_txt::inet; END IF;
  EXCEPTION WHEN others THEN ip_val := NULL;
  END;

  INSERT INTO monitor_results(
    time, monitor_id, module, target, success,
    probe_duration_seconds, resolve_ip, http_status_code,
    tls_cert_expiry_days, dns_lookup_seconds, tcp_connect_seconds,
    tls_handshake_seconds, http_duration_seconds, error_message, labels
  )
  VALUES (
    now_ts, m.id, m.module, m.target, ok,
    prom_value(resp_body, 'probe_duration_seconds'),
    ip_val,
    prom_int(resp_body, 'probe_http_status_code'),
    prom_value(resp_body, 'probe_ssl_earliest_cert_expiry'),
    prom_value(resp_body, 'probe_dns_lookup_time_seconds'),
    prom_value(resp_body, 'probe_tcp_connect_duration_seconds'),
    prom_value(resp_body, 'probe_tls_handshake_duration_seconds'),
    COALESCE(prom_value(resp_body, 'probe_http_duration_seconds'),
             prom_value(resp_body, 'http_client_request_duration_seconds')),
    CASE WHEN ok THEN NULL
         ELSE COALESCE(
                prom_label(resp_body, 'probe_failed_due_to_regex', 'reason'),
                prom_label(resp_body, 'probe_http_redirects', 'failure_reason'),
                err,
                'probe failed')
    END,
    dbg_labels
  );

  UPDATE monitors
  SET last_run_at = now_ts,
      last_status = ok,
      next_run_at = now_ts + m.period,
      updated_at  = now()
  WHERE id = m.id;
END;
$$;

-- 3) helper: show last N failed rows with first 300 chars of body
CREATE OR REPLACE VIEW v_recent_fail_debug AS
SELECT
  r.time, r.monitor_id, r.module, r.target, r.error_message,
  r.labels->>'url'       AS url,
  r.labels->>'body_head' AS body_head
FROM monitor_results r
WHERE r.success = false
ORDER BY r.time DESC
LIMIT 50;

