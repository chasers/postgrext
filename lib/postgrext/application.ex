defmodule Postgrext.Application do
  @moduledoc """
  Starts the connection pool, schema cache, and HTTP server when
  `PGRST_DB_URI` is configured; otherwise starts nothing so the library
  can be compiled and unit-tested without a database.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    config = Postgrext.Config.load()
    Postgrext.Config.put(config)

    Supervisor.start_link(children(config), strategy: :one_for_one, name: Postgrext.Supervisor)
  end

  defp children(config) do
    case config[:db_uri] do
      nil ->
        []

      _db_uri ->
        config[:adapter].children(config) ++
          [
            Postgrext.SchemaCache,
            {Bandit, plug: Postgrext.Router, port: config[:port]}
          ]
    end
  end
end
