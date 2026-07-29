defmodule DemoWeb.HealthController do
  @moduledoc """
  Lightweight health endpoints used by Kubernetes probes.

    * `GET /healthz`       -> liveness. Cheap, no dependencies. If the BEAM can
      answer this, the container is alive and should not be killed.
    * `GET /healthz/ready` -> readiness. Verifies the process can actually serve
      traffic, including a fast round-trip to PostgreSQL. A pod that cannot reach
      the DB is pulled out of the Service endpoints instead of serving errors.

  Both are intentionally plain Plug controller actions (no LiveView, no session)
  so probes never open a WebSocket or allocate a LiveView process.
  """
  use DemoWeb, :controller

  def live(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  def ready(conn, _params) do
    case check_repo() do
      :ok -> send_resp(conn, 200, "ready")
      :error -> send_resp(conn, 503, "not_ready")
    end
  end

  defp check_repo do
    Ecto.Adapters.SQL.query!(Demo.Repo, "SELECT 1", [], timeout: 2_000)
    :ok
  rescue
    _ -> :error
  end
end
