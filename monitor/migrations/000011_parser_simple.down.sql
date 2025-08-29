-- +goose Down
SET search_path = monitor, public;

-- Restore the previous (regex) versions from earlier migrations

CREATE OR REPLACE FUNCTION prom_value(body text, metric text)
RETURNS double precision AS $$
DECLARE
  m text := '^\\s*' || metric ||
            '(?:\\{[^}]*\\})?\\s+([-+]?((\\d+\\.?\\d*)|(\\.?\\d+))(?:[eE][-+]?\\d+)?)\\s*(?:#.*)?\\s*\\r?$';
  v text;
BEGIN
  SELECT (regexp_matches(line, m))[1]
    INTO v
  FROM regexp_split_to_table(replace(body, E'\r', ''), E'\n') AS line
  WHERE line ~ ('^\\s*' || metric);

  IF v IS NULL THEN
    RETURN NULL;
  END IF;
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

