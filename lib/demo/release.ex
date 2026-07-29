defmodule Demo.Release do
  @moduledoc """
  Release tasks that run *without* Mix being available.

  Inside a production OTP release there is no `mix` and no application source —
  only compiled BEAM files. Ecto's `mix ecto.migrate` therefore cannot be used.
  This module is the release-friendly equivalent and is invoked from
  `rel/overlays/bin/migrate` via `bin/demo eval "Demo.Release.migrate()"`.

  Migrations are run as a dedicated Kubernetes Job (Helm pre-install/pre-upgrade
  hook) so schema changes happen exactly once per deploy, before any new pod
  starts serving traffic — never as a race between N replicas.
  """
  @app :demo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
