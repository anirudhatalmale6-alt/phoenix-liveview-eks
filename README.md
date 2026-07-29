# Phoenix LiveView on AWS EKS — deployment guide

Production packaging for the provided Phoenix LiveView app: a hardened container
image plus a Helm chart tuned for long-lived WebSockets, bursty traffic, and
graceful draining on deploy/scale-down.

- **`Dockerfile`** — multi-stage build → self-contained OTP release, non-root,
  minimal Debian runtime, BEAM as PID 1. See `DECISIONS.md §1`.
- **`deploy/helm/phoenix-liveview/`** — Helm chart: Deployment, Service, HPA, PDB,
  Ingress (ALB), ConfigMap/Secret, migrate hook Job, ServiceAccount,
  (optional) ServiceMonitor.
- **`DECISIONS.md`** — every design choice and its justification.
- **`VERIFICATION.md`** — what was lab-tested and the actual output (incl. the
  graceful-shutdown-of-a-live-socket test).

## TL;DR

```bash
# Build & push
docker build -t <registry>/phoenix-liveview:0.1.0 .
docker push <registry>/phoenix-liveview:0.1.0

# Secret (prod: use External Secrets Operator / SecretsManager CSI instead)
kubectl create secret generic phoenix-liveview \
  --from-literal=DATABASE_URL='ecto://user:pass@<rds-endpoint>:5432/demo_prod' \
  --from-literal=SECRET_KEY_BASE="$(mix phx.gen.secret)"

# Deploy
helm upgrade --install rel deploy/helm/phoenix-liveview \
  --set image.repository=<registry>/phoenix-liveview --set image.tag=0.1.0 \
  --set secret.existingSecret=phoenix-liveview \
  --set config.PHX_HOST=<host> \
  --set ingress.enabled=true --set ingress.host=<host>
```

## Runtime configuration (env)

| Variable              | Required | Purpose                                             |
|-----------------------|----------|-----------------------------------------------------|
| `DATABASE_URL`        | yes      | RDS/Postgres connection (`ecto://user:pass@host/db`)|
| `SECRET_KEY_BASE`     | yes      | Phoenix signing/encryption (`mix phx.gen.secret`)   |
| `PHX_HOST`            | yes      | Public host for URLs + `check_origin`               |
| `PORT`                | no (4000)| HTTP listen port                                    |
| `POOL_SIZE`           | no (10)  | Ecto DB pool size                                   |
| `DATABASE_SSL`        | no       | `true` to enable TLS to RDS                         |
| `DATABASE_SSL_CA_CERT`| no       | Path to RDS CA bundle → `verify_peer`               |
| `CHECK_ORIGIN`        | no       | Override allowed WS origins (comma list, or `false`)|

## Cluster prerequisites (assumed provided by the platform)

- `metrics-server` (for the CPU-based HPA)
- AWS Load Balancer Controller (for the ALB `Ingress`)
- An RDS PostgreSQL instance reachable from the cluster
- Optional: Prometheus Adapter (connection-based HPA), External Secrets Operator,
  Prometheus Operator (ServiceMonitor)

## Cluster-side helpers

```bash
kubectl rollout status deploy/rel-phoenix-liveview
kubectl get hpa,pdb,svc,ingress -l app.kubernetes.io/name=phoenix-liveview
kubectl logs -l app.kubernetes.io/component=migrate --tail=50   # migration Job
```
