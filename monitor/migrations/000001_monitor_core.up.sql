-- +goose Up
-- Core schema: extensions, schema, types, settings, monitors, results, parsers, runner, cron, retention

-- Extensions (requires superuser/cluster setup; keep IF NOT EXISTS to be idempotent)
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS http;      -- pgsql-http
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Tidy schema
CREATE SCHEMA IF NOT EXISTS monitor;
SET search_path = monitor, public;

-- Global settings
CREATE TABLE IF NOT EXISTS settings (
  id                smallint PRIMARY KEY DEFAULT 1,
  blackbox_base     text        NOT NULL DEFAULT 'http://blackbox:9115',
  default_module    text        NOT NULL DEFAULT 'http_2xx',
  default_period    interval    NOT NULL DEFAULT interval '1 minute',
  default_retention interval    NOT NULL DEFAULT interval '30 days',
  http_timeout_ms   integer     NOT NULL DEFAULT 5000,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
INSERT INTO settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Monitor kind
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'monitor_kind') THEN
    CREATE TYPE monitor_kind AS ENUM('url','fqdn','ip');
  END IF;
END$$;

-- Monitors table
CREATE TABLE IF NOT EXISTS monitors (
  id               bigserial PRIMARY KEY,
  kind             monitor_kind NOT NULL,
  target           text         NOT NULL,
  module           text         NOT NULL,
  period           interval     NOT NULL,
  retention        interval     NOT NULL,
  enabled          boolean      NOT NULL DEFAULT true,
  next_run_at      timestamptz  NOT NULL DEFAULT now(),
  last_run_at      timestamptz,
  last_status      boolean,
  created_at       timestamptz  NOT NULL DEFAULT now(),
  updated_at       timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (kind, target, module)
);
CREATE INDEX IF NOT EXISTS monitors_due_idx ON monitors (enabled, next_run_at);

-- Results hypertable
CREATE TABLE IF NOT EXISTS monitor_results (
  time                    timestamptz NOT NULL,
  monitor_id              bigint      NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
  module                  text        NOT NULL,
  target                  text        NOT NULL,
  success                 boolean     NOT NULL,
  probe_duration_seconds  double precision,
  resolve_ip              inet,
  http_status_code        integer,
  tls_cert_expiry_days    double precision,
  dns_lookup_seconds      double precision,
  tcp_connect_seconds     double precision,
  tls_handshake_seconds   double precision,
  http_duration_seconds   double precision,
  error_message           text,
  labels                  jsonb
);
SELECT create_hypertable('monitor_results', 'time', if_not_exists => true);
CREATE INDEX IF NOT EXISTS monitor_results_mtime_idx ON monitor_results (monitor_id, time DESC);
CREATE INDEX IF NOT EXISTS monitor_results_target_idx ON monitor_results (target);
CREATE INDEX IF NOT EXISTS monitor_results_success_idx ON monitor_results (success, time DESC);

-- Compression + retention (global)
ALTER TABLE monitor_results SET (timescaledb.compress, timescaledb.compress_segmentby = 'monitor_id');
-- SELECT add_compression_policy('monitor_results', INTERVAL '2 days') ON CONFLICT DO NOTHING;
DO $$
BEGIN
  PERFORM add_compression_policy('monitor_results', INTERVAL '2 days');
EXCEPTION
  WHEN duplicate_object THEN
    -- policy already exists; do nothing
    NULL;
  WHEN others THEN
    -- older/newer Timescale versions may raise different errors; ignore if already present
    RAISE NOTICE 'add_compression_policy skipped: %', SQLERRM;
END$$;
SELECT add_retention_policy('monitor_results', INTERVAL '60 days', if_not_exists => true);

-- Parser helpers (Prometheus text exposition)
CREATE OR REPLACE FUNCTION prom_value(body text, metric text)
RETURNS double precision AS $$
DECLARE
  m text := metric || '(?:\\{[^}]*\\})?\\s+([-+]?\\d*\\.?\\d+(?:[eE][-+]?\\d+)?)\\s*$';
  v text;
BEGIN
  SELECT (regexp_matches(line, m))[1]
  INTO v
  FROM regexp_split_to_table(body, E'\n') AS line
  WHERE line ~ ('^' || metric);

  IF v IS NULL THEN RETURN NULL; END IF;
  RETURN v::double precision;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION prom_int(body text, metric text)
RETURNS integer AS $$
DECLARE dv double precision;
BEGIN
  dv := prom_value(body, metric);
  IF dv IS NULL THEN RETURN NULL; END IF;
  RETURN floor(dv)::int;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION prom_label(body text, metric text, label_key text)
RETURNS text AS $$
DECLARE
  re text := metric || '\\{[^}]*' || label_key || '="([^"]+)"[^}]*\\}\\s+[-+]?\\d*\\.?\\d+(?:[eE][-+]?\\d+)?\\s*$';
  v text;
BEGIN
  SELECT (regexp_matches(line, re))[1]
  INTO v
  FROM regexp_split_to_table(body, E'\n') AS line
  WHERE line ~ ('^' || metric || '\\{');
  RETURN v;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Helper: add_monitor
CREATE OR REPLACE FUNCTION add_monitor(
  p_kind monitor_kind,
  p_target text,
  p_module text DEFAULT NULL,
  p_period interval DEFAULT NULL,
  p_retention interval DEFAULT NULL
) RETURNS bigint AS $$
DECLARE
  s settings;
  new_id bigint;
BEGIN
  SELECT * INTO s FROM settings WHERE id = 1;
  INSERT INTO monitors(kind, target, module, period, retention)
  VALUES (
    p_kind,
    p_target,
    COALESCE(p_module, s.default_module),
    COALESCE(p_period, s.default_period),
    COALESCE(p_retention, s.default_retention)
  )
  ON CONFLICT (kind, target, module) DO UPDATE
  SET period=EXCLUDED.period, retention=EXCLUDED.retention, enabled=true, updated_at=now()
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- Silences: time-window and pattern-based
CREATE TABLE IF NOT EXISTS silences (
  id            bigserial PRIMARY KEY,
  monitor_id    bigint REFERENCES monitors(id) ON DELETE CASCADE,
  target_like   text,               -- optional wildcard (SQL LIKE, e.g. %.corp.example.com)
  module        text,               -- optional specific module
  starts_at     timestamptz NOT NULL DEFAULT now(),
  ends_at       timestamptz NOT NULL,
  reason        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (monitor_id IS NOT NULL OR target_like IS NOT NULL) -- at least one selector
);
CREATE INDEX IF NOT EXISTS silences_active_idx ON silences (starts_at, ends_at);

-- Runner: execute one monitor now
CREATE OR REPLACE FUNCTION run_monitor_once(p_monitor_id bigint)
RETURNS void AS $$
DECLARE
  s settings;
  m monitors;
  url text;
  resp http_response;
  body text;
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

  -- Silence check: skip if actively silenced
  IF EXISTS (
    SELECT 1 FROM silences si
    WHERE now() BETWEEN si.starts_at AND si.ends_at
      AND (
        (si.monitor_id = m.id)
        OR (si.target_like IS NOT NULL AND m.target LIKE si.target_like)
      )
      AND (si.module IS NULL OR si.module = m.module)
  ) THEN
    -- Advance schedule without probing
    UPDATE monitors
      SET last_run_at = now_ts, next_run_at = now_ts + m.period, updated_at = now()
      WHERE id = m.id;
    RETURN;
  END IF;

  url := s.blackbox_base || '/probe?module=' || urlencode(m.module) || '&target=' || urlencode(m.target);

  resp := http_get(url, ARRAY[ http_header('Accept','text/plain; version=0.0.4') ], s.http_timeout_ms);

  IF resp.status <> 200 THEN
    err := format('HTTP %s', resp.status);
    body := convert_from(COALESCE(resp.content, ''::bytea), 'UTF8');
  ELSE
    body := convert_from(resp.content, 'UTF8');
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

-- Runner: execute everything due (throttle/limit if needed)
CREATE OR REPLACE FUNCTION run_due_monitors()
RETURNS void AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT id
    FROM monitors
    WHERE enabled = true
      AND next_run_at <= now() + interval '1 second'
    ORDER BY next_run_at
    LIMIT 200
  LOOP
    PERFORM run_monitor_once(r.id);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Retention sweeper per monitor
CREATE OR REPLACE FUNCTION sweep_per_monitor_retention()
RETURNS void AS $$
DECLARE m RECORD;
BEGIN
  FOR m IN SELECT id, retention FROM monitors LOOP
    EXECUTE format(
      'DELETE FROM monitor_results WHERE monitor_id=$1 AND time < now() - $2::interval'
    ) USING m.id, m.retention;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Views
CREATE OR REPLACE VIEW v_monitor_latest AS
SELECT DISTINCT ON (m.id)
  m.id, m.kind, m.target, m.module, m.period, m.retention, m.enabled,
  r.time AS last_time, r.success, r.http_status_code, r.probe_duration_seconds,
  r.resolve_ip, r.tls_cert_expiry_days, m.next_run_at
FROM monitors m
LEFT JOIN monitor_results r ON r.monitor_id = m.id
ORDER BY m.id, r.time DESC;

CREATE OR REPLACE VIEW v_monitor_failures_24h AS
SELECT r.*
FROM monitor_results r
WHERE r.time > now() - interval '24 hours'
  AND r.success = false
ORDER BY r.time DESC;

-- pg_cron schedules (safe to re-run)
-- Note: ensure `ALTER SYSTEM SET cron.database_name = current_database();` and DB restart are done once at cluster-level.

-- Make sure we're in the right DB/schema first
SET search_path = monitor, public;

-- Due runner every minute
DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'monitor-due-runner') THEN
    PERFORM cron.schedule(
      'monitor-due-runner',
      '*/1 * * * *',
      'SELECT monitor.run_due_monitors();'
    );
  END IF;
END
$cron$;

-- Retention sweep daily at 03:15
DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'monitor-retention-sweeper') THEN
    PERFORM cron.schedule(
      'monitor-retention-sweeper',
      '15 3 * * *',
      'SELECT monitor.sweep_per_monitor_retention();'
    );
  END IF;
END
$cron$;

