kubectl -n "$NS" apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres-to-blackbox
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: blackbox
  policyTypes: ["Ingress"]
  ingress:
    - from:
        # Common CNPG labels; tweak if your labels differ
        - podSelector:
            matchExpressions:
              - key: app.kubernetes.io/part-of
                operator: In
                values: ["cloudnative-pg"]
        # (Optional) allow Prometheus to scrape too
        # - podSelector:
        #     matchLabels:
        #       app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9115
YAML

