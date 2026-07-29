# syntax=docker/dockerfile:1.7
# hadolint global ignore=DL3008,DL3059
#   DL3008 (pin apt versions): intentionally unpinned so `apt-get` picks up the
#          latest security patches for the pinned base image at build time.
#   DL3059 (consecutive RUNs): the builder's RUNs are split on purpose for Docker
#          layer-cache granularity (deps -> assets -> compile -> release).
# =============================================================================
# Multi-stage production image for the Phoenix LiveView application.
#
# Design decisions (see DECISIONS.md for the full rationale):
#   * Multi-stage: a fat builder (full Elixir/Erlang + build toolchain) produces
#     a self-contained OTP release; the final image ships only that release on a
#     minimal Debian runtime. Build tools, source, and Hex/Mix never reach prod.
#   * Artifact = `mix release`. It bundles the app, its deps, AND a trimmed ERTS
#     (Erlang runtime), so the runtime image needs no Elixir/Erlang installed and
#     boot is fast. BEAM chunks are stripped (strip_beams, default) to shrink it.
#   * PID 1 = the BEAM itself. `bin/server` execs `bin/demo start`, which execs
#     the emulator, so SIGTERM from Kubernetes reaches the VM directly and
#     triggers a graceful `init:stop()` (connection draining). No shell wrapper
#     swallowing signals, no separate init needed — the BEAM reaps its own OS
#     child processes.
#   * Non-root: the release runs as an unprivileged `app` user (uid 65532).
#   * No secrets in layers: all secrets (DATABASE_URL, SECRET_KEY_BASE, RDS CA)
#     are injected at runtime via env / mounted files, never build args or COPY.
#
# Pin exact tags so builds are reproducible. Keep builder Debian == runtime
# Debian so the compiled NIFs / ERTS link against the same libc/openssl.
# =============================================================================

ARG ELIXIR_VERSION=1.14.5
ARG OTP_VERSION=25.3.2.5
ARG DEBIAN_VERSION=bullseye-20240513-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# -----------------------------------------------------------------------------
# Stage 1 — builder
# -----------------------------------------------------------------------------
# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS builder

# Build-time OS deps. build-essential/git for any dep with a Makefile/NIF.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Hex + Rebar for the build user.
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# 1) Deps first — cached unless mix.exs/mix.lock change.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# 2) Compile-time config (config.exs + prod.exs). runtime.exs is copied later so
#    editing it does not bust the (expensive) dep-compilation cache.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# 3) Application source + assets.
COPY priv priv
COPY lib lib
COPY assets assets

# 4) Build & digest assets, then compile the app.
RUN mix assets.deploy
RUN mix compile

# 5) Runtime config + release overlays (server/migrate scripts, env.sh).
COPY config/runtime.exs config/
COPY rel rel

# 6) Assemble the self-contained release.
RUN mix release

# -----------------------------------------------------------------------------
# Stage 2 — runtime (minimal)
# -----------------------------------------------------------------------------
# hadolint ignore=DL3006
FROM ${RUNNER_IMAGE} AS runner

# Only the shared libs the BEAM needs at runtime. No compilers, no Elixir/Erlang.
# libssl/openssl for TLS to RDS; libncurses for the runtime; locales for UTF-8.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses5 locales ca-certificates tzdata \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Unprivileged runtime user (fixed high uid, matches the pod securityContext).
RUN groupadd --system --gid 65532 app \
  && useradd --system --uid 65532 --gid app --home /app --shell /usr/sbin/nologin app \
  && chown app:app /app

# Copy ONLY the built release from the builder, owned by the non-root user.
ENV MIX_ENV="prod"
COPY --from=builder --chown=app:app /app/_build/${MIX_ENV}/rel/demo ./

USER app

# Documented default; the actual bound port comes from $PORT at runtime.
ENV PORT=4000
EXPOSE 4000

# PID 1 is the BEAM (bin/server -> bin/demo start -> exec emulator), so SIGTERM
# is delivered straight to the VM for graceful LiveView connection draining.
ENTRYPOINT ["/app/bin/server"]
