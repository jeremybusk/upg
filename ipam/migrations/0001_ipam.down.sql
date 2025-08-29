-- Reverse of 0001_ipam.up.sql

SET search_path = public;

-- Drop views first (they depend on functions)
DROP VIEW IF EXISTS v_dns_forward_export;
DROP VIEW IF EXISTS v_dns_ptr_export;

-- Drop public API functions (exact signatures)
DROP FUNCTION IF EXISTS allocate_ip(BIGINT,BIGINT,TEXT,TEXT,INET);
DROP FUNCTION IF EXISTS allocate_subnet_ipv4(BIGINT,CIDR,INT,TEXT,TEXT,prefix_status);
DROP FUNCTION IF EXISTS remove_ip(BIGINT);
DROP FUNCTION IF EXISTS add_ip(BIGINT,INET,BIGINT,TEXT,TEXT,ip_status,BOOLEAN);
DROP FUNCTION IF EXISTS remove_prefix(BIGINT);
DROP FUNCTION IF EXISTS add_prefix(BIGINT,CIDR,prefix_status,BIGINT,TEXT,TEXT);

-- Drop triggers (then the trigger functions)
DROP TRIGGER IF EXISTS t_ip_must_fit_prefix ON ip_addresses;
DROP TRIGGER IF EXISTS t_prefixes_no_overlap ON prefixes;

DROP FUNCTION IF EXISTS trg_ip_must_fit_prefix();
DROP FUNCTION IF EXISTS trg_prefixes_no_overlap();

-- Drop helper functions
DROP FUNCTION IF EXISTS ptr_name(inet);
DROP FUNCTION IF EXISTS generate_ipv4_subnets(CIDR,INT);
DROP FUNCTION IF EXISTS cidr_last_host(CIDR);
DROP FUNCTION IF EXISTS cidr_first_host(CIDR);
DROP FUNCTION IF EXISTS int_to_ipv4(BIGINT);
DROP FUNCTION IF EXISTS ipv4_to_int(INET);

-- Drop indexes (IF EXISTS is optional; dropping tables will drop indexes implicitly)
-- (not required — omitted intentionally)

-- Drop tables (children first)
DROP TABLE IF EXISTS ip_addresses;
DROP TABLE IF EXISTS prefixes;
DROP TABLE IF EXISTS vrf;

-- Drop types
DROP TYPE IF EXISTS ip_status;
DROP TYPE IF EXISTS prefix_status;

