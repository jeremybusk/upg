-- +goose Down
SET search_path = monitor, public;

-- Revert to the simpler 3-arg form (will require that overload to exist)
CREATE OR REPLACE FUNCTION run_monitor_once(p_monitor_id bigint)
RETURNS void AS $$
DECLARE
  s settings;
  m monitors;
  url text;
  body text;
  ok boolean := false;
  err text := NULL;
  ip_txt text;
  ip_val inet;
  success_val double precision;
  now_ts timestamptz := now();
  resp_status int;
  resp_content bytea;
BEGIN
  SELECT * INTO s FROM settings WHERE id=1;
  SELECT * INTO m FROM monitors WHERE id=p_monitor_id AND enabled=true FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  IF EXISTS (
    SELECT 1 FROM silences si
    WHERE now() BETWEEN si.starts_at AND si.ends_at
      AND (
        si.monitor_id = m.id
        OR (si.target_like IS NOT NULL AND m.target LIKE si.target_like)
      )
      AND (si.module IS NULL OR si.module = m.module)
  ) THEN
    UPDATE monitors
      SET last_run_at = now_ts, next_run_at = now_ts + m.period, updated_at = now()
      WHERE id = m.id;
    RETURN;
  END IF;

  url := s.blackbox_base || '/probe?module=' || urlencode(m.module) || '&target=' || urlencode(m.target);

  SELECT status, content
    INTO resp_status, resp_content
  FROM http_get(
    url,
    ARRAY[ http_header('Accept','text/plain; version=0.0.4') ]::http_header[],
    s.http_timeout_ms::int
  );

  IF resp_status <> 200 THEN
    err := format('HTTP %s', resp_status);
    body := convert_from(COALESCE(resp_content, ''::bytea), 'UTF8');
  ELSE
    body := convert_from(resp_content, 'UTF8');
    success_val := prom_value(body, 'probe_success');
    ok := (success_val IS NOT NULL AND success_val > 0.5);
  END IF;

  ip_txt := COALESCE(
    prom_label(body, 'probe_http_ssl', 'ip'),
    prom_label(body, 'probe_dns_lookup_time_seconds', 'ip'),
    prom_label(body, 'probe_ip_connect_time_seconds', 'ip')
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
    prom_value(body, 'probe_duration_seconds'),
    ip_val,
    prom_int(body, 'probe_http_status_code'),
    prom_value(body, 'probe_ssl_earliest_cert_expiry'),
    prom_value(body, 'probe_dns_lookup_time_seconds'),
    prom_value(body, 'probe_tcp_connect_duration_seconds'),
    prom_value(body, 'probe_tls_handshake_duration_seconds'),
    COALESCE(prom_value(body, 'probe_http_duration_seconds'),
             prom_value(body, 'http_client_request_duration_seconds')),
    CASE WHEN ok THEN NULL
         ELSE COALESCE(
                prom_label(body, 'probe_failed_due_to_regex', 'reason'),
                prom_label(body, 'probe_http_redirects', 'failure_reason'),
                err, 'probe failed')
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
$$ LANGUAGE plpgsql;

