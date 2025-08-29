-- +goose Down
SET search_path = monitor, public;

-- Unschedule cron job
-- +goose StatementBegin
DO $cron$
DECLARE jid bigint;
BEGIN
  SELECT jobid INTO jid FROM cron.job WHERE jobname = 'monitor-alert-eval';
  IF jid IS NOT NULL THEN PERFORM cron.unschedule(jid); END IF;
END
$cron$;
-- +goose StatementEnd

DROP FUNCTION IF EXISTS evaluate_alerts();
DROP FUNCTION IF EXISTS notify_alert(text, jsonb);

DROP TABLE IF EXISTS alerts;
DROP TABLE IF EXISTS alert_policies;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'alert_condition') THEN
    DROP TYPE alert_condition;
  END IF;
END
$$;

