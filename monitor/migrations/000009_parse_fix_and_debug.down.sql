-- +goose Down
SET search_path = monitor, public;

-- Revert prom_label/value to previous 000008 definitions (without CR stripping)
CREATE OR REPLACE FUNCTION prom_label(body text, metric text, label_key text)
RETURNS text AS $$
DECLARE
  re text := '^\\s*' || metric || '\\{[^}]*' || label_key || '="([^"]*)"[^}]*\\}';
  v text;
BEGIN
  SELECT (regexp_matches(line, re))[1]
    INTO v
  FROM regexp_split_to_table(body, E'\n') AS line;
  RETURN v;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION prom_value(body text, metric text)
RETURNS double precision AS $$
DECLARE
  m text := '^\\s*' || metric ||
            '(?:\\{[^}]*\\})?\\s+([-+]?((\\d+\\.?\\d*)|(\\.?\\d+))(?:[eE][-+]?\\d+)?)\\s*(?:#.*)?$';
  v text;
BEGIN
  SELECT (regexp_matches(line, m))[1]
    INTO v
  FROM regexp_split_to_table(body, E'\n') AS line
  WHERE line ~ ('^\\s*' || metric);

  IF v IS NULL THEN RETURN NULL; END IF;
  RETURN v::double precision;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Recreate run_monitor_once from 000008 (without body_head debug)
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
  FROM probe_fetch(url, s.http_timeout_ms, 'text/plain; version=0.0.4');

  IF resp_status = 200 THEN
    success_val := prom_value(resp_body, 'probe_success');
    IF success_val IS NULL THEN
      ok := false;
      err := 'parse: missing probe_success';
    ELSE
      ok := (success_val > 0.5);
    END IF;
  ELSE
    ok := false;
    err := format('exporter HTTP %s', resp_status);
  END IF;

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

