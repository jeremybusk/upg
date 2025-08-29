SELECT (http_get('http://blackbox:9115/probe?module=http_2xx&target=http://example.com')).content AS response_content;

SELECT (http_get('http://blackbox:9115')).status AS response_status;

SELECT *
FROM monitor.probe_fetch('http://blackbox:9115/probe?module=http_2xx&target=https://example.com'
);

SELECT *
FROM monitor.probe_fetch(
  (SELECT blackbox_base FROM monitor.settings WHERE id=1) ||
  '/probe?module=' || (SELECT module FROM monitor.monitors WHERE id=1) ||
  '&target=' || (SELECT target FROM monitor.monitors WHERE id=1),
  (SELECT http_timeout_ms FROM monitor.settings WHERE id=1)
);

select * from monitors;

SELECT monitor.run_due_monitors();

-- Verify rows are now good
SELECT time, monitor_id, success, http_status_code, probe_duration_seconds, error_message
FROM monitor.monitor_results
ORDER BY time DESC
LIMIT 10;

-- If anything looks off, print the exact exporter response for a monitor (e.g., id=1)
SELECT * FROM monitor.debug_probe(1);


SELECT * FROM monitor.v_recent_fail_debug;

```
SELECT *
FROM cron.job_run_details
WHERE status = 'succeeded'
OR status = 'failed'
ORDER BY start_time DESC;
```











-- Add a few monitors (if not already)
SELECT monitor.add_monitor('url','https://example.com','http_2xx','30s','30 days');

-- Seed a simple policy (uncomment as needed)
INSERT INTO monitor.alert_policies(name, condition, threshold_num, eval_window, severity, target_like)
VALUES ('uptime<99%/1h','uptime_below',0.99,'1 hour','warning','%');

-- Kick runners manually once
SELECT monitor.run_due_monitors();
SELECT monitor.evaluate_alerts();

-- Inspect
SELECT * FROM monitor.v_monitor_status ORDER BY id;
SELECT * FROM monitor.alerts ORDER BY last_eval_at DESC;


```
-- Add one of each
SELECT add_monitor('url',  'https://example.com',   'http_2xx',    '30s', '14 days');
SELECT add_monitor('fqdn', 'example.com',          'dns',         '1m',  '30 days');
SELECT add_monitor('ip',   '1.1.1.1:53',           'tcp_connect', '30s', '14 days');

-- Force-run now
SELECT run_due_monitors();

-- See results
SELECT * FROM v_monitor_latest ORDER BY id;
SELECT * FROM v_monitor_failures_24h LIMIT 10;
```


```
-- Make a failing monitor (bad port)
SELECT add_monitor('url','http://example.com:81','http_2xx','30s','7 days') AS bad_id\gset
SELECT run_monitor_once(:bad_id::bigint);

-- Policy: fire if the latest check failed
INSERT INTO alert_policies(name, condition, threshold_num, severity, monitor_id)
VALUES ('1x-fail','consecutive_failures', 1, 'critical', :bad_id)
RETURNING id;

-- Evaluate now and see alerts
SELECT evaluate_alerts();
SELECT * FROM alerts ORDER BY last_eval_at DESC LIMIT 5;

-- (Optional) watch NOTIFY in another psql session:
--   LISTEN monitor_alerts;
--   -- then rerun evaluate_alerts() or trigger new failures
```


SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname LIKE 'monitor-%';
SELECT * FROM cron.job_run_details ORDER BY end_time DESC LIMIT 10;



###


-- 1) Force-run one monitor & inspect latest
SELECT run_due_monitors();

SELECT * FROM v_monitor_latest ORDER BY id;

-- 2) Debug a specific monitor (replace 1)
SELECT * FROM debug_probe(1);

-- 3) See raw rows
SELECT time, monitor_id, success, http_status_code, probe_duration_seconds, error_message
FROM monitor_results
ORDER BY time DESC
LIMIT 10;

