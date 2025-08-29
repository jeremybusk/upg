# http

https://github.com/pramsey/pgsql-http


SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

SELECT * FROM cron.job;


# Examples

## Nightly VACUUM

```
SELECT cron.schedule('nightly-vacuum', '0 10 * * *', 'VACUUM');
```

## Simple get into table

```
-- Step 1: Create the http extension if it doesn't exist.
-- This extension provides the http_get() function.
-- You will need superuser privileges to create extensions.
CREATE EXTENSION IF NOT EXISTS http;

-- Step 2: Create a table to store the HTTP response.
-- The http_get() function returns a composite type with fields:
-- status (integer), content (text), and headers (text).
-- We'll create columns to store the status code and the response content.
CREATE TABLE IF NOT EXISTS http_responses (
    id SERIAL PRIMARY KEY,
    url TEXT NOT NULL,
    response_status INT,
    response_content TEXT,
    fetched_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Step 3: Insert the response from an HTTP request into the table.
-- The `SELECT` statement accesses the fields from the composite type returned by http_get().
INSERT INTO http_responses (url, response_status, response_content)
SELECT
    'http://example.com' AS url,
    (http_get('http://example.com')).status AS response_status,
    (http_get('http://example.com')).content AS response_content;

-- Optional: View the data in your new table.
SELECT * FROM http_responses;

```


## Monitor

```
-- Create the http extension if it doesn't exist.
CREATE EXTENSION IF NOT EXISTS http;

-- Create the pg_cron extension if it doesn't exist.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Create a table to store the HTTP response.
CREATE TABLE IF NOT EXISTS http_responses (
    id SERIAL PRIMARY KEY,
    url TEXT NOT NULL,
    response_status INT,
    response_content TEXT,
    fetched_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Function to check a URL, save the response, and send a notification if the status or content is not as expected.
CREATE OR REPLACE FUNCTION monitor_http_url(
    p_url TEXT,
    p_expected_status INT,
    p_content_regex TEXT
)
RETURNS VOID AS $$
DECLARE
    v_response_record http_response;
    v_message TEXT;
BEGIN
    -- Perform the HTTP GET request.
    v_response_record := http_get(p_url);

    -- Insert the response into the history table.
    INSERT INTO http_responses (url, response_status, response_content)
    VALUES (p_url, v_response_record.status, v_response_record.content);

    -- Check if the status code is not the expected one or if the content does not match the regex.
    IF v_response_record.status <> p_expected_status OR NOT v_response_record.content ~ p_content_regex THEN
        v_message := FORMAT(
            'HTTP Monitor Alert: URL %s returned status %s (expected %s) or content did not match regex. Content snippet: %s',
            p_url,
            v_response_record.status,
            p_expected_status,
            LEFT(v_response_record.content, 100)
        );
        PERFORM pg_notify('http_monitor_channel', v_message);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Set pg_cron to use background workers to avoid connection issues.
ALTER SYSTEM SET cron.use_background_workers = on;

-- Schedule the first pg_cron job to run the monitoring function every 60 seconds.
-- This job monitors example.com, expecting a 200 status and a response with "Example" in the content.
-- You can replace the URL, status, and regex with your own monitoring targets.
SELECT cron.schedule(
    'http-monitor',
    '*/1 * * * *',
    'SELECT monitor_http_url(''http://example.com'', 200, ''.*Example.*'')'
);

-- Schedule a second pg_cron job to clean up old data in the http_responses table every 120 seconds.
-- This prevents the table from growing indefinitely.
SELECT cron.schedule(
    'http-cleanup',
    '*/2 * * * *',
    'DELETE FROM http_responses WHERE fetched_at < NOW() - INTERVAL ''1 day'''
);

-- To listen for notifications, connect to the database in a separate session and run:
-- LISTEN http_monitor_channel;

```
