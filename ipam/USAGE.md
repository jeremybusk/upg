```
-- One default VRF
INSERT INTO vrf(name) VALUES ('default') ON CONFLICT DO NOTHING;

-- Add a container to subdivide: 10.0.0.0/16
SELECT add_prefix( (SELECT id FROM vrf WHERE name='default'),
                   '10.0.0.0/16'::cidr, 'container', NULL, 'netops', 'Corp LAN');

-- Allocate an IPv4 /24 inside that /16
SELECT * FROM allocate_subnet_ipv4(
  p_vrf_id := (SELECT id FROM vrf WHERE name='default'),
  p_within := '10.0.0.0/16',
  p_new_len := 24,
  p_owner := 'team-a',
  p_desc := 'Team A segment',
  p_status := 'allocated'
);
-- -> returns new prefix id and the chosen /24 (e.g., 10.0.0.0/24)

-- Allocate first-free host IP from that /24
SELECT * FROM allocate_ip(
  p_vrf_id := (SELECT id FROM vrf WHERE name='default'),
  p_parent_prefix_id := (SELECT id FROM prefixes WHERE prefix='10.0.0.0/24'),
  p_hostname := 'host1.example.com'
);

-- Reserve a static address within same /24
SELECT add_ip(
  p_vrf_id := (SELECT id FROM vrf WHERE name='default'),
  p_address := '10.0.0.254/32',
  p_prefix_id := (SELECT id FROM prefixes WHERE prefix='10.0.0.0/24'),
  p_hostname := 'gw1.example.com',
  p_desc := 'Default gateway',
  p_status := 'reserved',
  p_is_static := TRUE
);

-- Add IPv6 container (static)
SELECT add_prefix((SELECT id FROM vrf WHERE name='default'),
                  '2001:db8:100::/48','container',NULL,'netops','IPv6 space');

-- Allocate an IPv6 /64 statically under the /48:
SELECT add_prefix((SELECT id FROM vrf WHERE name='default'),
                  '2001:db8:100::/64','allocated',
                  (SELECT id FROM prefixes WHERE prefix='2001:db8:100::/48'),
                  'team-a','Team A v6 seg');

-- Add a static IPv6 host in that /64
SELECT add_ip((SELECT id FROM vrf WHERE name='default'),
              '2001:db8:100::10/128',
              (SELECT id FROM prefixes WHERE prefix='2001:db8:100::/64'),
              'host1-v6.example.com', 'static v6', 'allocated', TRUE);

-- Export PTRs
SELECT * FROM v_dns_ptr_export;      -- ptr_fqdn + hostname_fqdn
SELECT * FROM v_dns_forward_export;  -- hostname_fqdn + address

```
