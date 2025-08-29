```
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'monitor'
      AND pid <> pg_backend_pid();


    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'TARGET_DB_NAME'
      AND pid <> pg_backend_pid();
```

```
SELECT extname, extnamespace::regnamespace FROM pg_extension WHERE extname='http';
SELECT typname, typnamespace::regnamespace FROM pg_type WHERE typname='http_response';

```


## Set search path for all connections

```
    ALTER DATABASE your_database_name SET search_path TO schema1, schema2, public;
```


## pg_cron

### Single cron with search paths

```
    SELECT cron.schedule('my_job', '0 0 * * *', 'SET search_path TO myschema, public; SELECT my_function();');
    update cron.job set schedule='*/1 * * * *', command='SET search_path TO monitor, public; SELECT monitor.evaluate_alerts();' where jobid=6;
```

### Every 2 minutes

```
*/2 * * * * /path/to/your/command_or_script
```

```
SELECT *
FROM cron.job_run_details
WHERE status = 'succeeded'
OR status = 'failed'
ORDER BY start_time DESC;
```
