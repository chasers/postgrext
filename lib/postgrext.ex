defmodule Postgrext do
  @moduledoc """
  PostgREST reimplemented in Elixir: serves a RESTful API straight from a
  PostgreSQL schema, speaking PostgREST's query syntax.

  Configure through PostgREST-compatible environment variables (see
  `Postgrext.Config`) and start the application; tables, views, and functions
  in the exposed schemas become HTTP endpoints (see `Postgrext.Router`).
  """
end
