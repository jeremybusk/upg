-- +goose Up
SET search_path = monitor, public;

-- Fix ambiguity by qualifying http_get columns with an alias
CREATE OR REPLACE FUNCTION probe_fetch(
  p_url text,
  p_timeout_ms integer DEFAULT 5000,
  p_accept text DEFAULT 'text/plain; version=0.0.4'
) RETURNS TABLE(status int, body text)
LANGUAGE plpgsql AS $$
DECLARE
  s int;
  c bytea;
BEGIN
  -- Try 3-arg -> 2-arg -> 1-arg http_get, always alias as h
  BEGIN
    SELECT h.status, h.content INTO s, c
    FROM http_get(
      p_url,
      ARRAY[ http_header('Accept', p_accept) ]::http_header[],
      p_timeout_ms::int
    ) AS h;
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      SELECT h.status, h.content INTO s, c
      FROM http_get(
        p_url,
        ARRAY[ http_header('Accept', p_accept) ]::http_header[]
      ) AS h;
    EXCEPTION WHEN undefined_function THEN
      SELECT h.status, h.content INTO s, c
      FROM http_get(p_url) AS h;
    END;
  END;

  status := s;
  body   := convert_from(COALESCE(c, ''::bytea), 'UTF8');
  RETURN NEXT;
END;
$$;

