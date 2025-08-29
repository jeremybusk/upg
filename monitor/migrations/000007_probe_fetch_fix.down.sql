-- +goose Down
SET search_path = monitor, public;

-- Restore the previous (buggy) version — only if you really need to roll back
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
  BEGIN
    SELECT status, content INTO s, c
    FROM http_get(
      p_url,
      ARRAY[ http_header('Accept', p_accept) ]::http_header[],
      p_timeout_ms::int
    );
  EXCEPTION WHEN undefined_function THEN
    BEGIN
      SELECT status, content INTO s, c
      FROM http_get(
        p_url,
        ARRAY[ http_header('Accept', p_accept) ]::http_header[]
      );
    EXCEPTION WHEN undefined_function THEN
      SELECT status, content INTO s, c
      FROM http_get(p_url);
    END;
  END;

  status := s;
  body   := convert_from(COALESCE(c, ''::bytea), 'UTF8');
  RETURN NEXT;
END;
$$;

