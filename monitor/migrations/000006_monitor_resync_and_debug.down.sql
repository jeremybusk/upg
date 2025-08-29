-- +goose Down
SET search_path = monitor, public;

DROP FUNCTION IF EXISTS debug_probe(bigint);
DROP VIEW IF EXISTS v_monitor_latest;
DROP FUNCTION IF EXISTS probe_fetch(text, integer, text);

-- Recreate v_monitor_latest (same definition as before 000006)
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

