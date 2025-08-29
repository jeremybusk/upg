-- IPAM schema, helpers, triggers, allocators, and DNS export views
-- Works on PostgreSQL 12+ (tested on PG 17). No extensions required.

SET search_path = public;

-- =========================
-- ENUMs
-- =========================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'prefix_status') THEN
    CREATE TYPE prefix_status AS ENUM ('allocated','container','reserved');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ip_status') THEN
    CREATE TYPE ip_status   AS ENUM ('allocated','reserved');
  END IF;
END $$;

-- =========================
-- Tables
-- =========================

CREATE TABLE IF NOT EXISTS vrf (
  id         BIGSERIAL PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS prefixes (
  id          BIGSERIAL PRIMARY KEY,
  vrf_id      BIGINT NOT NULL REFERENCES vrf(id) ON DELETE CASCADE,
  parent_id   BIGINT NULL REFERENCES prefixes(id) ON DELETE SET NULL,
  prefix      CIDR   NOT NULL,
  status      prefix_status NOT NULL DEFAULT 'allocated',
  description TEXT,
  owner       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT prefixes_unique UNIQUE (vrf_id, prefix)
);

CREATE TABLE IF NOT EXISTS ip_addresses (
  id            BIGSERIAL PRIMARY KEY,
  vrf_id        BIGINT NOT NULL REFERENCES vrf(id) ON DELETE CASCADE,
  prefix_id     BIGINT NULL  REFERENCES prefixes(id) ON DELETE SET NULL,
  address       INET   NOT NULL,
  status        ip_status NOT NULL DEFAULT 'allocated',
  hostname_fqdn TEXT,
  description   TEXT,
  is_static     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ip_hostmask CHECK (masklen(address) IN (32,128)),
  CONSTRAINT ip_unique UNIQUE (vrf_id, address)
);

-- =========================
-- Indexes
-- =========================
CREATE INDEX IF NOT EXISTS idx_prefixes_vrf     ON prefixes(vrf_id);
CREATE INDEX IF NOT EXISTS idx_prefixes_parent  ON prefixes(parent_id);
CREATE INDEX IF NOT EXISTS idx_ipaddr_vrf       ON ip_addresses(vrf_id);
CREATE INDEX IF NOT EXISTS idx_ipaddr_prefix    ON ip_addresses(prefix_id);

-- =========================
-- Helpers (IPv4 math & PTR)
-- =========================

-- IPv4 <-> int
CREATE OR REPLACE FUNCTION ipv4_to_int(ip INET)
RETURNS BIGINT LANGUAGE sql IMMUTABLE STRICT AS $$
SELECT ((split_part(host($1),'.',1)::bigint*256
      +  split_part(host($1),'.',2)::bigint)*256
      +  split_part(host($1),'.',3)::bigint)*256
      +  split_part(host($1),'.',4)::bigint
$$;

CREATE OR REPLACE FUNCTION int_to_ipv4(n BIGINT)
RETURNS INET LANGUAGE sql IMMUTABLE STRICT AS $$
SELECT ( ((n >> 24) & 255)::text || '.' ||
         ((n >> 16) & 255)::text || '.' ||
         ((n >>  8) & 255)::text || '.' ||
         ( n        & 255)::text )::inet
$$;

-- First/last usable host within a CIDR
CREATE OR REPLACE FUNCTION cidr_first_host(c CIDR)
RETURNS INET LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE base INET := network(c);
BEGIN
  IF family(c) = 4 THEN
    RETURN int_to_ipv4(ipv4_to_int(base)+1);
  ELSE
    -- IPv6: first usable is the network address (no broadcast concept)
    RETURN base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION cidr_last_host(c CIDR)
RETURNS INET LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
  IF family(c) = 4 THEN
    RETURN int_to_ipv4(ipv4_to_int(broadcast(c)) - 1);
  ELSE
    -- Not used in v6 dynamic path; return some upper bound typed as inet
    RETURN set_masklen(c::inet, 128);
  END IF;
END $$;

-- Generate aligned IPv4 child subnets of size new_len inside parent
CREATE OR REPLACE FUNCTION generate_ipv4_subnets(parent CIDR, new_len INT)
RETURNS SETOF CIDR LANGUAGE sql STABLE AS $$
WITH params AS (
  SELECT masklen(parent) AS pfx_len,
         ipv4_to_int(network(parent)) AS base_int
),
span AS (
  SELECT (1 << (new_len - pfx_len))::BIGINT AS subnet_count,
         (1 << (32 - new_len))::BIGINT      AS block_size
  FROM params
)
SELECT set_masklen(int_to_ipv4(base_int + i*block_size), new_len)::cidr
FROM params, span, generate_series(0, (SELECT subnet_count-1 FROM span)) AS g(i)
$$;

-- Reverse-DNS name for IPv4/IPv6 (robust; no regex; uses inet_send/get_byte)
CREATE OR REPLACE FUNCTION ptr_name(ip inet)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
SELECT CASE
  WHEN family($1) = 4 THEN
       get_byte(inet_send($1), 3)::text || '.' ||
       get_byte(inet_send($1), 2)::text || '.' ||
       get_byte(inet_send($1), 1)::text || '.' ||
       get_byte(inet_send($1), 0)::text || '.in-addr.arpa'
  ELSE
       (
         SELECT string_agg(substr(hx, j, 1), '.') || '.ip6.arpa'
         FROM (
           SELECT string_agg(lpad(to_hex(get_byte(inet_send($1), i)), 2, '0'), '') AS hx
           FROM generate_series(0, 15) AS g(i)
         ) AS bytes
         CROSS JOIN LATERAL generate_series(32, 1, -1) AS n(j)
       )
END
$$;

-- =========================
-- Triggers / Constraints
-- =========================

-- Disallow overlapping allocated/reserved prefixes within the same VRF
-- (containers are allowed to nest and are ignored here)
CREATE OR REPLACE FUNCTION trg_prefixes_no_overlap()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IN ('allocated','reserved') THEN
    PERFORM 1
      FROM prefixes p
     WHERE p.vrf_id = NEW.vrf_id
       AND p.id <> COALESCE(NEW.id, -1)
       AND p.status IN ('allocated','reserved')
       AND (
             NEW.prefix << p.prefix
          OR p.prefix  << NEW.prefix
          OR NEW.prefix = p.prefix
       );
    IF FOUND THEN
      RAISE EXCEPTION 'Prefix % in VRF % overlaps/conflicts', NEW.prefix, NEW.vrf_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS t_prefixes_no_overlap ON prefixes;
CREATE TRIGGER t_prefixes_no_overlap
BEFORE INSERT OR UPDATE ON prefixes
FOR EACH ROW EXECUTE FUNCTION trg_prefixes_no_overlap();

-- Ensure IP belongs to its prefix (if given); block IPv4 network/broadcast
CREATE OR REPLACE FUNCTION trg_ip_must_fit_prefix()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE pfx CIDR;
BEGIN
  IF NEW.prefix_id IS NOT NULL THEN
    SELECT prefix INTO pfx FROM prefixes WHERE id = NEW.prefix_id;
    IF pfx IS NULL THEN
      RAISE EXCEPTION 'prefix_id % not found', NEW.prefix_id;
    END IF;
    IF NOT (NEW.address << pfx) THEN
      RAISE EXCEPTION 'IP % must be inside prefix %', NEW.address, pfx;
    END IF;
    IF family(pfx) = 4 THEN
      IF host(network(pfx))::inet = NEW.address THEN
        RAISE EXCEPTION 'Cannot allocate network address % in %', NEW.address, pfx;
      END IF;
      IF broadcast(pfx) IS NOT NULL AND broadcast(pfx)::inet = NEW.address THEN
        RAISE EXCEPTION 'Cannot allocate broadcast address % in %', NEW.address, pfx;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS t_ip_must_fit_prefix ON ip_addresses;
CREATE TRIGGER t_ip_must_fit_prefix
BEFORE INSERT OR UPDATE ON ip_addresses
FOR EACH ROW EXECUTE FUNCTION trg_ip_must_fit_prefix();

-- =========================
-- Public API (CRUD + allocators)
-- =========================

-- Add/remove prefix
CREATE OR REPLACE FUNCTION add_prefix(
  p_vrf_id BIGINT,
  p_prefix CIDR,
  p_status prefix_status DEFAULT 'allocated',
  p_parent_id BIGINT DEFAULT NULL,
  p_owner TEXT DEFAULT NULL,
  p_desc  TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE new_id BIGINT;
BEGIN
  INSERT INTO prefixes(vrf_id, prefix, status, parent_id, owner, description)
  VALUES (p_vrf_id, p_prefix, p_status, p_parent_id, p_owner, p_desc)
  RETURNING id INTO new_id;
  RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION remove_prefix(p_prefix_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM prefixes WHERE id = p_prefix_id;
END $$;

-- Add/remove IP
CREATE OR REPLACE FUNCTION add_ip(
  p_vrf_id BIGINT,
  p_address INET,
  p_prefix_id BIGINT DEFAULT NULL,
  p_hostname TEXT DEFAULT NULL,
  p_desc TEXT DEFAULT NULL,
  p_status ip_status DEFAULT 'allocated',
  p_is_static BOOLEAN DEFAULT TRUE
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE new_id BIGINT;
BEGIN
  INSERT INTO ip_addresses(vrf_id, address, prefix_id, hostname_fqdn, description, status, is_static)
  VALUES (p_vrf_id, p_address, p_prefix_id, p_hostname, p_desc, p_status, p_is_static)
  RETURNING id INTO new_id;
  RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION remove_ip(p_ip_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM ip_addresses WHERE id = p_ip_id;
END $$;

-- First-fit IPv4 subnet allocation inside p_within
CREATE OR REPLACE FUNCTION allocate_subnet_ipv4(
  p_vrf_id BIGINT,
  p_within CIDR,
  p_new_len INT,
  p_owner TEXT DEFAULT NULL,
  p_desc  TEXT DEFAULT NULL,
  p_status prefix_status DEFAULT 'allocated'
) RETURNS TABLE(out_id BIGINT, out_prefix CIDR)
LANGUAGE plpgsql
AS $$
DECLARE
  cand CIDR;
  parent_row_id BIGINT;
BEGIN
  IF family(p_within) <> 4 THEN
    RAISE EXCEPTION 'allocate_subnet_ipv4 only supports IPv4 (got %)', p_within;
  END IF;
  IF p_new_len < masklen(p_within) OR p_new_len > 32 THEN
    RAISE EXCEPTION 'new_len % must be between % and 32 for %', p_new_len, masklen(p_within), p_within;
  END IF;

  -- IMPORTANT: qualify table id with alias p.
  SELECT p.id INTO parent_row_id
  FROM prefixes p
  WHERE p.vrf_id = p_vrf_id AND p.prefix = p_within
  LIMIT 1;

  FOR cand IN SELECT * FROM generate_ipv4_subnets(p_within, p_new_len) LOOP
    -- conflict with any allocated/reserved?
    PERFORM 1
      FROM prefixes p
     WHERE p.vrf_id = p_vrf_id
       AND p.status IN ('allocated','reserved')
       AND (cand << p.prefix OR p.prefix << cand OR cand = p.prefix);

    IF NOT FOUND THEN
      INSERT INTO prefixes (vrf_id, prefix, status, parent_id, owner, description)
      VALUES (p_vrf_id, cand, p_status, parent_row_id, p_owner, p_desc)
      RETURNING prefixes.id, prefixes.prefix INTO out_id, out_prefix;
      RETURN;
    END IF;
  END LOOP;

  RAISE EXCEPTION 'No free /% subnet available inside % in VRF %', p_new_len, p_within, p_vrf_id;
END
$$;


-- First-fit IPv4 host allocation (or preferred static v4/v6)
CREATE OR REPLACE FUNCTION allocate_ip(
  p_vrf_id BIGINT,
  p_parent_prefix_id BIGINT,
  p_hostname TEXT DEFAULT NULL,
  p_desc TEXT DEFAULT NULL,
  p_preferred INET DEFAULT NULL
) RETURNS TABLE(out_id BIGINT, out_address INET)
LANGUAGE plpgsql
AS $$
DECLARE
  pfx      CIDR;
  first    INET;
  last     INET;
  next_ip  INET;
BEGIN
  SELECT p.prefix INTO pfx
  FROM prefixes p
  WHERE p.id = p_parent_prefix_id AND p.vrf_id = p_vrf_id;

  IF pfx IS NULL THEN
    RAISE EXCEPTION 'Parent prefix % not found in VRF %', p_parent_prefix_id, p_vrf_id;
  END IF;

  IF p_preferred IS NOT NULL THEN
    IF NOT (p_preferred << pfx) THEN
      RAISE EXCEPTION 'Preferred IP % must be inside %', p_preferred, pfx;
    END IF;
    IF family(pfx)=4 THEN
      IF host(network(pfx))::inet = p_preferred THEN
        RAISE EXCEPTION 'Preferred % is network address of %', p_preferred, pfx;
      END IF;
      IF broadcast(pfx) IS NOT NULL AND broadcast(pfx)::inet = p_preferred THEN
        RAISE EXCEPTION 'Preferred % is broadcast address of %', p_preferred, pfx;
      END IF;
    END IF;

    INSERT INTO ip_addresses(vrf_id, prefix_id, address, hostname_fqdn, description, is_static)
    VALUES (p_vrf_id, p_parent_prefix_id, p_preferred, p_hostname, p_desc, TRUE)
    RETURNING ip_addresses.id, ip_addresses.address INTO out_id, out_address;
    RETURN;
  END IF;

  IF family(pfx)=4 THEN
    first := cidr_first_host(pfx);
    last  := cidr_last_host(pfx);

    SELECT int_to_ipv4(g.i)::inet
      INTO next_ip
    FROM generate_series(ipv4_to_int(first), ipv4_to_int(last)) AS g(i)
    LEFT JOIN ip_addresses a
           ON a.vrf_id = p_vrf_id AND a.address = int_to_ipv4(g.i)::inet
    WHERE a.id IS NULL
    ORDER BY g.i
    LIMIT 1;

    IF next_ip IS NULL THEN
      RAISE EXCEPTION 'No free host IP available in %', pfx;
    END IF;

    INSERT INTO ip_addresses(vrf_id, prefix_id, address, hostname_fqdn, description, is_static)
    VALUES (p_vrf_id, p_parent_prefix_id, next_ip, p_hostname, p_desc, FALSE)
    RETURNING ip_addresses.id, ip_addresses.address INTO out_id, out_address;
    RETURN;
  ELSE
    RAISE EXCEPTION 'Dynamic IPv6 host allocation not implemented in this build (provide p_preferred)';
  END IF;
END
$$;


-- =========================
-- DNS export views
-- =========================
DROP VIEW IF EXISTS v_dns_ptr_export;
DROP VIEW IF EXISTS v_dns_forward_export;

CREATE OR REPLACE VIEW v_dns_ptr_export AS
SELECT a.vrf_id, a.address, ptr_name(a.address) AS ptr_fqdn, a.hostname_fqdn
FROM ip_addresses a
WHERE a.hostname_fqdn IS NOT NULL;

CREATE OR REPLACE VIEW v_dns_forward_export AS
SELECT a.vrf_id, a.hostname_fqdn, a.address
FROM ip_addresses a
WHERE a.hostname_fqdn IS NOT NULL;

-- (Optional) seed a default VRF:
-- INSERT INTO vrf(name) VALUES ('default') ON CONFLICT DO NOTHING;

