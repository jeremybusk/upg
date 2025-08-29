-- +goose Up
SET search_path = monitor, public;

-- 1) Condition enum
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'alert_condition') THEN
    CREATE TYPE alert_condition AS ENUM ('uptime_below', 'p95_over', 'consecutive_failures');
  END IF;
END
$$;

-- 2) Policies (rules)
CREATE TABLE IF NOT EXISTS alert_policies (
  id               bigserial PRIMARY KEY,
  name             text               NOT NULL,
  condition        alert_condition    NOT NULL,
  threshold_num    double precision   NOT NULL,
  -- meaning by condition:
  --   uptime_below: threshold_num in [0,1]
  --   p95_over:     seconds (double)
  --   consecutive_failures: integer (cast from double)
  eval_window      interval,          -- required for uptime_below/p95_over
  severity         text               NOT NULL DEFAULT 'warning',  -- "info"|"warning"|"critical"
  enabled          boolean            NOT NULL DEFAULT true,
  monitor_id       bigint REFERENCES monitors(id) ON DELETE CASCADE,
  target_like      text,              -- alternative selector (SQL LIKE)
  module           text,              -- optional module filter
  for_minutes      integer,           -- reserved
  created_at       timestamptz        NOT NULL DEFAULT now(),
  updated_at       timestamptz        NOT NULL DEFAULT now(),
  CHECK (
    (condition = 'consecutive_failures' AND eval_window IS NULL)
    OR
    (condition IN ('uptime_below','p95_over') AND eval_window IS NOT NULL)
  ),
  CHECK ((monitor_id IS NOT NULL) OR (target_like IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS alert_policies_enabled_idx ON alert_policies (enabled);

-- 3) Alerts (instances)
CREATE TABLE IF NOT EXISTS alerts (
  id             bigserial PRIMARY KEY,
  policy_id      bigint      NOT NULL REFERENCES alert_policies(id) ON DELETE CASCADE,
  monitor_id     bigint      NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
  state          text        NOT NULL,  -- "firing"|"resolved"
  started_at     timestamptz NOT NULL,
  ended_at       timestamptz,
  last_eval_at   timestamptz NOT NULL,
  reason         text,
  severity       text        NOT NULL,
  dedup_key      text        NOT NULL,  -- policy_id:monitor_id
  labels         jsonb,
  annotations    jsonb,
  UNIQUE (dedup_key, state, started_at)
);

CREATE INDEX IF NOT EXISTS alerts_active_idx ON alerts (state, last_eval_at DESC);
CREATE INDEX IF NOT EXISTS alerts_monitor_idx ON alerts (monitor_id, last_eval_at DESC);

-- 4) NOTIFY helper
CREATE OR REPLACE FUNCTION notify_alert(p_event text, p_payload jsonb)
RETURNS void AS $$
BEGIN
  PERFORM pg_notify('monitor_alerts', jsonb_build_object('event', p_event, 'data', p_payload)::text);
END;
$$ LANGUAGE plpgsql;

-- 5) Evaluator
CREATE OR REPLACE FUNCTION evaluate_alerts()
RETURNS void AS $$
DECLARE
  p         alert_policies%ROWTYPE;
  m         monitors%ROWTYPE;
  now_ts    timestamptz := now();
  firing    boolean;
  reason    text;
  p95       double precision;
  uptime    double precision;
  nfail     integer;
  dedup     text;
  last_alert RECORD;
BEGIN
  FOR p IN SELECT * FROM alert_policies WHERE enabled = true LOOP

    FOR m IN
      SELECT *
      FROM monitors
      WHERE enabled = true
        AND (
          (p.monitor_id IS NOT NULL AND id = p.monitor_id)
          OR
          (p.monitor_id IS NULL AND p.target_like IS NOT NULL AND target LIKE p.target_like)
        )
        AND (p.module IS NULL OR module = p.module)
    LOOP
      firing := false;
      reason := NULL;

      IF p.condition = 'uptime_below' THEN
        SELECT
          SUM(CASE WHEN success THEN 1 ELSE 0 END)::double precision
          / GREATEST(COUNT(*),1)
        INTO uptime
        FROM monitor_results
        WHERE monitor_id = m.id
          AND time >= now_ts - p.eval_window;

        IF uptime IS NOT NULL AND uptime < p.threshold_num THEN
          firing := true;
          reason := format('uptime %.2f < threshold %.2f over %s', uptime, p.threshold_num, p.eval_window::text);
        END IF;

      ELSIF p.condition = 'p95_over' THEN
        SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY probe_duration_seconds)
        INTO p95
        FROM monitor_results
        WHERE monitor_id = m.id
          AND time >= now_ts - p.eval_window
          AND probe_duration_seconds IS NOT NULL;

        IF p95 IS NOT NULL AND p95 > p.threshold_num THEN
          firing := true;
          reason := format('p95 %.3fs > threshold %.3fs over %s', p95, p.threshold_num, p.eval_window::text);
        END IF;

      ELSIF p.condition = 'consecutive_failures' THEN
        SELECT COUNT(*) INTO nfail
        FROM (
          SELECT success
          FROM monitor_results
          WHERE monitor_id = m.id
          ORDER BY time DESC
          LIMIT CEIL(p.threshold_num)::int
        ) t
        WHERE t.success = false;

        IF nfail = CEIL(p.threshold_num)::int AND nfail > 0 THEN
          firing := true;
          reason := format('last %s checks failed', CEIL(p.threshold_num)::int);
        END IF;
      END IF;

      dedup := p.id::text || ':' || m.id::text;

      SELECT *
      INTO last_alert
      FROM alerts
      WHERE dedup_key = dedup AND state = 'firing'
      ORDER BY started_at DESC
      LIMIT 1;

      IF firing THEN
        IF last_alert IS NULL THEN
          INSERT INTO alerts(
            policy_id, monitor_id, state, started_at, last_eval_at,
            severity, reason, dedup_key, labels, annotations
          )
          VALUES (
            p.id, m.id, 'firing', now_ts, now_ts,
            p.severity, reason, dedup,
            jsonb_build_object('module', m.module, 'target', m.target),
            jsonb_build_object('policy', p.name)
          )
          RETURNING * INTO last_alert;

          PERFORM notify_alert(
            'firing',
            jsonb_build_object('id', last_alert.id, 'policy_id', p.id, 'monitor_id', m.id, 'severity', p.severity, 'reason', reason)
          );
        ELSE
          UPDATE alerts
             SET last_eval_at = now_ts,
                 reason       = COALESCE(reason, last_alert.reason)
           WHERE id = last_alert.id;
        END IF;
      ELSE
        IF last_alert IS NOT NULL THEN
          UPDATE alerts
             SET state = 'resolved',
                 ended_at = now_ts,
                 last_eval_at = now_ts
           WHERE id = last_alert.id;

          PERFORM notify_alert(
            'resolved',
            jsonb_build_object('id', last_alert.id, 'policy_id', p.id, 'monitor_id', m.id)
          );
        END IF;
      END IF;

    END LOOP; -- monitors
  END LOOP; -- policies
END;
$$ LANGUAGE plpgsql;
-- 6) Cron: evaluate every minute
-- +goose StatementBegin
DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'monitor-alert-eval') THEN
    PERFORM cron.schedule(
      'monitor-alert-eval',
      '*/1 * * * *',
      'SELECT monitor.evaluate_alerts();'
    );
  END IF;
END
$cron$;
-- +goose StatementEnd

