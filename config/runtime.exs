import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# ---------------------------------------------------------------------------
# Start the web server when running as a release.
#
# `mix phx.server` sets this automatically in dev; a release does not. The
# rel/overlays/bin/server script exports PHX_SERVER=true so the endpoint boots.
# ---------------------------------------------------------------------------
if System.get_env("PHX_SERVER") do
  config :demo, DemoWeb.Endpoint, server: true
end

# The block below contains prod specific runtime configuration.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # RDS connectivity. Enable TLS with DATABASE_SSL=true (recommended for RDS).
  # When verifying certificates, point DATABASE_SSL_CA_CERT at the RDS CA bundle
  # (mounted from a Secret/ConfigMap) so the connection is verify_peer, not
  # verify_none. Defaults stay permissive-free: no TLS unless asked for.
  maybe_ssl_opts =
    if System.get_env("DATABASE_SSL") in ~w(true 1) do
      ca_cert = System.get_env("DATABASE_SSL_CA_CERT")

      verify =
        if ca_cert do
          [verify: :verify_peer, cacertfile: ca_cert, server_name_indication: :disable]
        else
          # No CA supplied: still encrypt, but cannot verify the peer.
          [verify: :verify_none]
        end

      [ssl: true, ssl_opts: verify]
    else
      [ssl: false]
    end

  config :demo,
         Demo.Repo,
         [
           url: database_url,
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           # Bound queue time so a saturated pool sheds load fast instead of
           # letting latency-sensitive requests pile up behind the DB.
           queue_target: 50,
           queue_interval: 1000,
           socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])
         ] ++ maybe_ssl_opts

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # check_origin protects the LiveView WebSocket from cross-site connections.
  # Behind an ALB/Ingress the browser Origin is the public host, so we allow the
  # configured host (http+https). Override with a comma list via CHECK_ORIGIN.
  check_origin =
    case System.get_env("CHECK_ORIGIN") do
      nil -> ["//#{host}", "https://#{host}", "http://#{host}"]
      "false" -> false
      list -> String.split(list, ",", trim: true)
    end

  config :demo, DemoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind on all interfaces (IPv4). Set ECTO_IPV6-style dual stack at the LB.
      ip: {0, 0, 0, 0},
      port: port,
      # Cowboy transport tuning for many long-lived WebSocket connections.
      transport_options: [num_acceptors: 100, max_connections: 16_384]
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base,
    # Graceful connection draining on shutdown. When the BEAM receives SIGTERM
    # the endpoint's drainer stops accepting new sockets and gives in-flight
    # (LiveView) connections up to `shutdown` ms to finish/reconnect elsewhere
    # before the listener is torn down. Must be < terminationGracePeriodSeconds.
    drainer: [shutdown: 30_000, drain_check_interval: 1_000]
end
