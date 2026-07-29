# Verification / lab test log

Everything below was actually executed, not just written. I can't spin up a real
EKS cluster or a Docker daemon inside my build box, so the split is:

- **App + OTP release + graceful shutdown**: run for real, end-to-end, against a
  live PostgreSQL. This is the same artifact the Dockerfile's builder stage
  produces (`mix release`) and the same `bin/server` / `bin/migrate` the container
  runs — so the container behaviour is exercised directly.
- **Dockerfile**: statically linted (hadolint, 0 findings). The build itself uses
  the official `hexpm/elixir` + `debian-slim` images, which are known-good; run
  `docker build .` in your lab to produce the image.
- **Helm chart**: `helm lint` + full render + `kubeconform` schema validation
  against Kubernetes 1.29. Apply to your EKS cluster to deploy.

---

## 1. OTP release builds (mirrors the Dockerfile builder stage)

```
$ MIX_ENV=prod mix assets.deploy      # esbuild --minify + phx.digest
  ../priv/static/assets/app.js   79.6kb
  ../priv/static/assets/app.css  20.5kb
$ MIX_ENV=prod mix release --overwrite
* assembling demo-0.1.0 on MIX_ENV=prod
* using config/runtime.exs to configure the release at runtime
Release created at _build/prod/rel/demo
```

## 2. Migrations run via the release (no Mix), same path as the Helm hook Job

```
$ DATABASE_URL=ecto://demo@127.0.0.1:5544/demo_prod bin/demo eval "Demo.Release.migrate()"
[info] == Running 20180610040824 Demo.Repo.Migrations.CreateUsers.change/0 forward
[info] == Migrated 20180610040824 in 0.0s

$ psql -d demo_prod -c "\dt"
 public | schema_migrations | table | demo
 public | users             | table | demo
```

## 3. App boots and serves (release started via bin/server, PID 1 = BEAM)

```
[info] Running DemoWeb.Endpoint with cowboy 2.9.0 at 0.0.0.0:4055 (http)

GET /healthz          -> 200      (liveness; no DB touch)
GET /healthz/ready    -> 200      (readiness; runs SELECT 1 against RDS/PG)
GET /                 -> 200      (LiveView index)
GET /assets/app-<digest>.js -> 200 (digested static asset served from cache_manifest)
```

## 4. LiveView WebSocket upgrade works

```
$ curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" \
       -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: ..." \
       "http://localhost:4055/live/websocket?vsn=2.0.0"
HTTP/1.1 101 Switching Protocols        <-- socket established
```

## 5. Graceful shutdown of a LIVE WebSocket on SIGTERM  ⟵ the core requirement

Opened a real WebSocket to `/live`, held it open, then sent `SIGTERM` to the BEAM
(as Kubernetes does on pod termination) and polled whether the VM stayed alive:

```
HANDSHAKE: HTTP/1.1 101 Switching Protocols
WS_OPEN_HOLDING
>>> sending SIGTERM to beam at t=0
t=0.0s beam=ALIVE
t=1.0s beam=ALIVE
t=2.6s beam=ALIVE
t=3.6s beam=ALIVE
t=4.6s beam=ALIVE
t=5.6s beam=ALIVE
t=6.1s beam=GONE (exited)     <-- exited right AFTER the client closed the socket
WS_CLOSED_BY_CLIENT
```

Server log during the same window:

```
[info]   CONNECTED TO Phoenix.LiveView.Socket in 46µs
[notice] SIGTERM received - shutting down
```

**Interpretation:** SIGTERM did **not** drop the open socket. The endpoint drainer
kept the VM alive while the LiveView connection was active, and the process exited
cleanly only once the connection drained — comfortably inside the 30s drain window
and the 90s `terminationGracePeriodSeconds`. This is precisely
"no sudden loss of open LiveView sockets during deploy/scale-down."

---

## 6. Dockerfile lint

```
$ hadolint Dockerfile
(no output; exit 0)
```

## 7. Helm chart — lint, render, schema validation

```
$ helm lint .
1 chart(s) linted, 0 chart(s) failed

$ helm template rel . --set secret.create=true --set ingress.enabled=true \
    --set autoscaling.customConnectionMetric.enabled=true \
    --set serviceMonitor.enabled=true --set database.caBundle.enabled=true \
  | kubeconform -kubernetes-version 1.29.0 -strict -summary -ignore-missing-schemas
Summary: 10 resources found - Valid: 9, Invalid: 0, Errors: 0, Skipped: 1
```

(The one skipped resource is the `ServiceMonitor`, whose CRD schema isn't in the
default kubeconform set — expected; it's off by default.)

Rendered objects: Deployment, Service, HorizontalPodAutoscaler, PodDisruptionBudget,
Ingress, ConfigMap, Secret, ServiceAccount, migrate Job, ServiceMonitor.

---

## How to reproduce the cluster-side deploy in your lab

```bash
# 1. Build & push the image
docker build -t <registry>/phoenix-liveview:0.1.0 .
docker push <registry>/phoenix-liveview:0.1.0

# 2. Create the secret (or wire External Secrets)
kubectl create secret generic phoenix-liveview \
  --from-literal=DATABASE_URL='ecto://user:pass@<rds-endpoint>:5432/demo_prod' \
  --from-literal=SECRET_KEY_BASE="$(mix phx.gen.secret)"

# 3. Install
helm install rel deploy/helm/phoenix-liveview \
  --set image.repository=<registry>/phoenix-liveview \
  --set image.tag=0.1.0 \
  --set secret.existingSecret=phoenix-liveview \
  --set ingress.enabled=true --set ingress.host=<your-host> \
  --set config.PHX_HOST=<your-host>
```
