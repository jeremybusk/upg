-- +goose Up
SET search_path = monitor, public;

-- Ultra-tolerant numeric extractor: scans lines, no brittle anchors
CREATE OR REPLACE FUNCTION prom_value(body text, metric text)
RETURNS double precision
LANGUAGE plpgsql AS $$
DECLARE
  ln text;
  t  text;
  trimmed text;
  mlen int := length(metric);
  nextc text;
BEGIN
  -- Normalize CRLF -> LF, split into lines
  FOR ln IN
    SELECT line
    FROM regexp_split_to_table(replace(body, E'\r', ''), E'\n') AS line
  LOOP
    IF ln IS NULL THEN CONTINUE; END IF;

    trimmed := btrim(ln);

    -- skip blank or comment lines
    IF trimmed = '' OR left(trimmed,1) = '#' THEN CONTINUE; END IF;

    -- must start with the metric name
    IF left(trimmed, mlen) <> metric THEN CONTINUE; END IF;

    -- char immediately after metric must be '{' or whitespace (or end)
    nextc := substr(trimmed, mlen+1, 1);
    IF nextc IS NOT NULL AND nextc NOT IN ('{',' ','	') THEN CONTINUE; END IF;

    -- extract the FINAL numeric token on the line
    SELECT substring(trimmed FROM '([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)(?:\s*(?:#.*)?)?$')
      INTO t;

    IF t IS NOT NULL AND t ~ '^[+-]?\d' THEN
      RETURN t::double precision;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION prom_int(body text, metric text)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE dv double precision;
BEGIN
  dv := prom_value(body, metric);
  IF dv IS NULL THEN RETURN NULL; END IF;
  RETURN floor(dv)::int;
END;
$$;

