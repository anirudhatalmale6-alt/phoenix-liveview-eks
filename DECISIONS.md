# Design decisions & justifications

This document explains the *why* behind the Dockerfile and Kubernetes manifests.
The brief explicitly asked us to make and justify several calls — those are
marked **[DECISION]**.

---

## 1. Container image

### [DECISION] Production artifact = a `mix release` (self-contained OTP release)

The builder stage runs `mix release`, producing a self-contained release under
`_build/prod/rel/demo`. This bundles:

- the compiled application and all its dependencies,
- a **trimmed copy of ERTS** (the Erlang runtime), and
- boot scripts (`bin/demo`, plus our `bin/server` and `bin/migrate` overlays).

Why a release rather than shipping source + `mix phx.server`:

- The runtime image needs **no Elixir, no Mix, no Hex** — smaller and less
  attack surface.
- Config is loaded at boot from `config/runtime.exs`, so the *same* image runs in
  any environment; secrets come from env at runtime, never from the image.
- Releases give first-class **remote console, `eval`, and graceful `stop`**, which
  we use for migrations and for clean shutdown.
- BEAM debug chunks are stripped (`strip_beams`, the default) to shrink the image.

### [DECISION] What runs as PID 1

**The BEAM (the Erlang VM) runs as PID 1** — no `tini`, no shell wrapper left in
the process tree. `ENTRYPOINT ["/app/bin/server"]` → `bin/server` does
`exec ./bin/demo start` → the release start script `exec`s the emulator. Every
link in the chain uses `exec`, so the VM inherits PID 1.

Rationale:

- **Signals go straight to the VM.** Kubernetes sends `SIGTERM` on pod
  termination. Delivered directly to the BEAM, it triggers the VM's default
  signal handler → `init:stop()` → orderly application shutdown → our endpoint
  **connection drainer** runs. A shell wrapper (`/bin/sh -c "..."`) would become
  PID 1 and, unless it `exec`s, would **not** forward `SIGTERM` — LiveView sockets
  would be killed abruptly on the grace-period `SIGKILL`. That is exactly the
  failure mode the brief calls out.
- **Zombie reaping is not a concern here.** The usual reason to add `tini` is to
  reap orphaned children. The BEAM manages and reaps its own OS child processes
  (via `erl_child_setup`), and this app spawns no external `os:cmd`/port
  subprocesses that would orphan. So `tini` would add a layer without benefit.
  (If a future workload shells out heavily, add `tini -g -- /app/bin/server` and
  keep everything else.)

### [DECISION] Base images

- Builder: `hexpm/elixir:1.14.5-erlang-25.3.2.5-debian-bullseye-*-slim` — matches
  the app's `~> 1.12` Elixir and OTP 25.
- Runtime: `debian:bullseye-*-slim` — **same Debian release as the builder** so the
  release's ERTS and any NIFs link against the identical `glibc`/`openssl`.

Why Debian-slim and not `alpine` or `distroless`:

- Alpine uses musl; the BEAM and some NIFs are happiest on glibc, and musl DNS
  resolver quirks have bitten Erlang clustering. Debian-slim avoids that class of
  bug for a small size cost.
- Distroless would be smaller still, but we deliberately keep a minimal shell so
  the **`preStop` `sleep`** and `bin/migrate`/remote-console work without extra
  plumbing. It is still minimal (no compilers, no package managers left in the
  final layer). This is a conscious size-vs-operability trade.

### Security & hygiene in the image

- **Non-root**: a dedicated `app` user (uid/gid 65532) owns and runs the release;
  the pod `securityContext` pins the same uid and adds `runAsNonRoot`.
- **No secrets in layers**: nothing sensitive is `COPY`ed or passed as build args.
  `.dockerignore` keeps `_build/`, `deps/`, `.git/`, `.env*`, and `*.secret.exs`
  out of the build context.
- **Layer caching**: deps are fetched/compiled before app source is copied, so
  ordinary code changes don't re-fetch Hex packages.

---

## 2. Application changes made for production

The sample app was dev-oriented. Minimal, surgical changes (see `git diff`):

- `config/runtime.exs`: start the server in releases (`PHX_SERVER`), read
  `DATABASE_URL`/`SECRET_KEY_BASE`/`PHX_HOST`/`PORT`/`POOL_SIZE` from env, add
  **RDS TLS** (`DATABASE_SSL`, optional CA bundle → `verify_peer`), set
  `check_origin` for the WebSocket, and configure the **endpoint drainer**
  (`drainer: [shutdown: 30_000, ...]`) for graceful shutdown.
- `lib/demo/release.ex` + `rel/overlays/bin/migrate`: run migrations without Mix
  inside the release.
- `rel/overlays/bin/server` + `rel/env.sh.eex`: boot the web server; name the
  node after `POD_IP` so clustering is possible later.
- `lib/demo_web/controllers/health_controller.ex` + routes: cheap `/healthz`
  (liveness) and `/healthz/ready` (readiness, does a `SELECT 1`).
- `lib/demo_web/live/page_live.ex`: guard the dev-only LiveDashboard link so the
  index page doesn't 500 in prod (pre-existing bug in the sample).

---

## 3. Kubernetes

### [DECISION] Service type — ClusterIP behind an ALB Ingress, with stickiness

LiveView holds a **stateful WebSocket**: the LiveView process and its assigns live
on **one specific pod**. If a client's traffic is bounced to a different pod
mid-session it must re-establish and rebuild state. So:

- **Service is `ClusterIP`** (not `LoadBalancer` per-pod, not `NodePort`). North-
  south traffic enters through **one ALB** managed by an `Ingress`. The ALB speaks
  WebSockets natively (no config needed) and terminates TLS.
- **Stickiness in two layers**: ALB target-group `lb_cookie` stickiness (primary,
  at the edge) + Service `sessionAffinity: ClientIP` (secondary). A returning
  browser lands on the same pod, keeping the LiveView session stable.
- **`target-type: ip`** so the ALB routes to pod IPs directly (cleaner draining,
  fewer hops) and target **deregistration_delay** is set so in-flight requests
  drain from the target group before a pod is pulled.

### [DECISION] HPA scaling signal

**Primary signal: CPU utilisation vs requests (target 60%).** Justification:

- For this app the real cost — rendering LiveView diffs and pushing them over
  many WebSockets, plus PubSub fan-out — shows up as **CPU**. CPU tracks load well
  and is available from `metrics-server` with **no extra adapter**, so it's the
  pragmatic, reliable default.
- Target 60% (not 80–90%) leaves headroom for **bursty, sharp peaks**: we want to
  add capacity *before* latency degrades, not after CPU is already saturated.

**Why not memory as the primary signal:** BEAM memory is dominated by process
heaps and binary refc; it grows and plateaus and doesn't shrink promptly, so it's
a poor *proportional* scaling signal. We keep a memory **target as a secondary
guard** only.

**The ideal signal, wired but off by default:** for a WebSocket server the most
honest signal is **active connections per pod**. The chart includes a `Pods`
metric (`customConnectionMetric`) for exactly this — enable it once a Prometheus
Adapter exposes the metric (Phoenix already emits connection telemetry). It's off
by default because it needs cluster-side wiring we can't assume.

**Scale *behaviour* matters more than the target for this workload:**

- **Scale up fast** (`stabilizationWindowSeconds: 0`, up to +100% or +4 pods / 15s)
  to catch sharp peaks.
- **Scale down slowly** (`stabilizationWindowSeconds: 300`, ≤1 pod/min). Removing a
  pod terminates its sockets; we don't want to yank pods after a brief lull and
  cause reconnect storms. Conservative scale-down protects the sockets.

### [DECISION] PodDisruptionBudget

`minAvailable: 50%`. Voluntary disruptions (node drain for an upgrade, cluster
autoscaler consolidation) must never take out the whole fleet — and with it every
open socket — at once. With 3+ replicas this keeps at least half serving while
nodes are recycled, and it forces the drain to happen **pod by pod**, each one
going through the graceful drain path below.

### Graceful shutdown — the end-to-end chain

This is the core requirement ("open LiveView sockets should not be dropped
abruptly"). The pieces compose:

1. Pod marked `Terminating` → removed from Service/ALB endpoints.
2. **`preStop: sleep 15`** — gives that removal time to propagate so **no new**
   connections are still being routed here when we start shutting down.
3. **`SIGTERM`** to the BEAM (PID 1) → `init:stop()`.
4. **Endpoint drainer** stops accepting new sockets and waits up to **30s** for
   existing LiveView connections to finish / reconnect elsewhere.
5. **`terminationGracePeriodSeconds: 90`** > 15 + 30, so the kubelet never
   `SIGKILL`s mid-drain.
6. **`maxUnavailable: 0` + `maxSurge: 1`** on rollout, plus **PDB** and **topology
   spread**, guarantee there are always healthy pods elsewhere for drained
   sockets to reconnect to.

This chain was **verified locally** — see `VERIFICATION.md`: with a live WebSocket
open, `SIGTERM` did **not** kill the VM; it stayed up until the connection closed,
then exited cleanly, well within the grace period.

### Resources — [DECISION] memory limit, no CPU limit

- **Requests** set for reliable bin-packing and as the HPA denominator.
- **Memory limit** set (`512Mi`) — OOM protection against a runaway.
- **No CPU limit by default.** A CPU limit enforces CFS quota; when a latency-
  sensitive service briefly needs a burst, the quota **throttles** it and adds
  tail latency — the opposite of what we want here. The BEAM already spreads work
  across schedulers, and the HPA + requests handle capacity. (The knob is there
  if a hard cap is required for cost/multi-tenancy reasons.)

### Other hardening

- `securityContext`: `runAsNonRoot`, `readOnlyRootFilesystem: true` (with a
  writable `/tmp` `emptyDir`), `allowPrivilegeEscalation: false`, drop **ALL**
  capabilities, `seccompProfile: RuntimeDefault`.
- `automountServiceAccountToken: false` — the app needs no Kubernetes API access.
- **Migrations** run once per release as a Helm `pre-install/pre-upgrade` **hook
  Job** (`bin/migrate`), so N replicas never race to migrate.
- **Topology spread** across zones + soft **pod anti-affinity** across nodes so a
  single node/AZ loss can't drop the whole fleet.
- ConfigMap checksum annotation rolls pods when non-secret config changes.

---

## 4. What I deliberately left out (and how to add it)

- **libcluster / distributed Erlang**: not required for this exercise (Phoenix
  PubSub within a pod is enough for the demo LiveViews). The release is already
  node-named from `POD_IP`, so adding `libcluster` with the `Kubernetes.DNS`
  strategy + a headless Service is a small, clean follow-up if cross-pod Presence
  is needed.
- **Cluster prerequisites** (metrics-server, AWS Load Balancer Controller,
  Prometheus Adapter, External Secrets Operator) are assumed to be provided by the
  platform, as is the RDS instance. `values.yaml` has the switches for each.
