-- +goose Up
SET search_path = monitor, public;

-- 1) Helper: robust fetch from blackbox (works across pgsql-http versions)
CREATE OR REPLACE FUNCTION probe_fetch(p_url text, p_timeout_ms integer DEFAULT 5000, p_accept text DEFAULT 'text/plain; version=0.0.4')
RETURNS TABLE(status int, body text)
LANGUAGE plpgsql AS $$
DECLARE
  s int;
  c bytea;
BEGIN
  -- Try 3-arg -> 2-arg -> 1-arg http_get
  BEGIN
    SELECT status, content
      INTO s, c
    FROM http_get(
      p_url,
      ARRAY[ http_header('Accept', p_accept) ]::http_header[],
      p_timeout_ms::int
    );
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      SELECT status, content
        INTO s, c
      FROM http_get(
        p_url,
        ARRAY[ http_header('Accept', p_accept) ]::http_header[]
      );
    EXCEPTION WHEN undefined_function THEN
      SELECT status, content
        INTO s, c
      FROM http_get(p_url);
    END;
  END;

  status := s;
  body   := convert_from(COALESCE(c, ''::bytea), 'UTF8');
  RETURN NEXT;
END;
$$;

-- 2) Replace runner to use probe_fetch and safer URL building
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
BEGIN
  SELECT * INTO s FROM settings WHERE id=1;
  SELECT * INTO m FROM monitors WHERE id=p_monitor_id AND enabled=true FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Silences
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

  -- Encode target if uri_encode/urlencode exists; otherwise use as-is
  targ_encoded := m.target;
  BEGIN
    SELECT uri_encode(m.target) INTO targ_encoded;   -- pgsql-http provides this on some builds
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      SELECT urlencode(m.target) INTO targ_encoded;  -- if you have a custom urlencode()
    EXCEPTION WHEN undefined_function THEN
      targ_encoded := m.target;
    END;
  END;

  url := s.blackbox_base || '/probe?module=' || m.module || '&target=' || targ_encoded;

  -- Fetch from blackbox
  SELECT status, body INTO resp_status, resp_body
  FROM probe_fetch(url, s.http_timeout_ms, 'text/plain; version=0.0.4');

  IF resp_status = 200 THEN
    success_val := prom_value(resp_body, 'probe_success');
    ok := (success_val IS NOT NULL AND success_val > 0.5);
  ELSE
    err := format('exporter HTTP %s', resp_status);
    ok := false;
  END IF;

  -- Try to extract a resolved IP from any of these lines (optional)
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
    NULL
  );

  UPDATE monitors
  SET last_run_at = now_ts,
      last_status = ok,
      next_run_at = now_ts + m.period,
      updated_at  = now()
  WHERE id = m.id;
END;
$$;

-- 3) Recreate v_monitor_latest to ensure alignment
CREATE OR REPLACE VIEW v_monitor_latest AS
SELECT DISTINCT ON (m.id)
  m.id, m.kind, m.target, m.module, m.period, m.retention, m.enabled,
  r.time AS last_time,
  r.success,
  r.http_status_code,
  r.probe_duration_seconds,
  r.resolve_ip,
  r.tls_cert_expiry_days,
  m.next_run_at
FROM monitors m
LEFT JOIN monitor_results r
  ON r.monitor_id = m.id
ORDER BY m.id, r.time DESC;

-- 4) Debug helper: preview the exact call and parsed bits
CREATE OR REPLACE FUNCTION debug_probe(p_monitor_id bigint)
RETURNS TABLE(
  url text,
  exporter_status int,
  body_sample text,
  parsed_probe_success double precision,
  parsed_http_code integer
)
LANGUAGE plpgsql AS $$
DECLARE
  s settings;
  m monitors;
  targ_encoded text;
  full_url text;
  st int;
  bd text;
BEGIN
  SELECT * INTO s FROM settings WHERE id=1;
  SELECT * INTO m FROM monitors WHERE id=p_monitor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'monitor % not found', p_monitor_id;
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

  full_url := s.blackbox_base || '/probe?module=' || m.module || '&target=' || targ_encoded;

  SELECT status, body INTO st, bd FROM probe_fetch(full_url, s.http_timeout_ms);

  url := full_url;
  exporter_status := st;
  body_sample := substring(bd from 1 for 2000);
  parsed_probe_success := prom_value(bd, 'probe_success');
  parsed_http_code := prom_int(bd, 'probe_http_status_code');
  RETURN NEXT;
END;
$$;

