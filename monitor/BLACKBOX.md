```
UPDATE monitor.settings
SET blackbox_base = 'http://blackbox:9115',
    updated_at = now()
WHERE id = 1;

```

```
kubectl -n "$NS" run curl --rm -it --image=curlimages/curl:8.10.1 -- \
  sh -lc 'curl -s "http://blackbox:9115/probe?module=http_2xx&target=https://example.com" | head'
```

```
export NS=upg; kubectl -n "$NS" run curl --rm -it --image=curlimages/curl:8.10.1 --   sh -lc 'curl -s "http://blackbox:9115/probe?module=http_2xx&target=https://example.com" | head'
```

```
fullnameOverride: blackbox

config:
  modules:
    http_2xx:
      prober: http
      timeout: 5s
      http:
        method: GET
        follow_redirects: true
        preferred_ip_protocol: "ip4"
        # valid_http_versions: ["HTTP/1.1","HTTP/2.0"]  # Optional; safe to omit

    tcp_connect:
      prober: tcp
      timeout: 5s
      tcp:
        preferred_ip_protocol: "ip4"

    dns:
      prober: dns
      timeout: 5s
      dns:
        query_name: "{{.Target}}"
        query_type: "A"
        transport_protocol: "udp"
        preferred_ip_protocol: "ip4"

```
