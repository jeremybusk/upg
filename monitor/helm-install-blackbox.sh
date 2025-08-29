#!/bin/bash
set -eu

# pick your namespace (same one your CNPG/Postgres runs in)
NS=upg   # <-- change me

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# helm repo update

# Install/upgrade with our config
  # -n "$NS" --create-namespace \
helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter \
  -n "$NS" \
  -f - <<'EOF'
fullnameOverride: blackbox   # Service DNS becomes: http://blackbox:9115 in this namespace

image:
  pullPolicy: IfNotPresent

# Keep logs clean, change to debug if needed
extraArgs:
  - --log.level=info

# Configure the modules we call from Postgres
config:
  modules:
    http_2xx:
      prober: http
      timeout: 5s
      http:
        method: GET
        preferred_ip_protocol: "ip4"
        # valid_http_versions: ["HTTP/1.1","HTTP/2.0"]
        follow_redirects: true
        fail_if_ssl: false
        fail_if_not_ssl: false
        valid_status_codes: [200, 201, 202, 203, 204, 205, 206, 207, 208, 226]
        # fail_if_body_not_matches_regexp:
        # - ".*"
        tls_config:
          insecure_skip_verify: false
          ca_file: /etc/ssl/certs/ca-certificates.crt

    tcp_connect:
      prober: tcp
      timeout: 5s
      tcp:
        preferred_ip_protocol: "ip4"

    dns:
      prober: dns
      timeout: 5s
      dns:
        # Use the target passed on the URL as the query name
        query_name: "{{.Target}}"
        query_type: "A"
        transport_protocol: "udp"
        preferred_ip_protocol: "ip4"
        # To force a specific DNS server, uncomment:
        # dns_over_tcp: false
        # tls_config: {}
        # nameserver: "8.8.8.8:53"

service:
  type: ClusterIP
  port: 9115

resources:
  requests:
    cpu: 25m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi

# If you also run Prometheus Operator, you can expose a ServiceMonitor:
serviceMonitor:
  enabled: false
  # enable and select your Prometheus by label if you want to scrape it:
  # additionalLabels:
  #   release: kube-prometheus-stack
EOF

