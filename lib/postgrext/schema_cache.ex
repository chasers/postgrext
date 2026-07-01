defmodule Postgrext.SchemaCache do
  @moduledoc """
  Holds the introspected database structure in `:persistent_term` for fast
  lock-free reads. Loaded at startup; `refresh/0` re-introspects on demand.
  """

  use GenServer

  @key {__MODULE__, :cache}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: map()
  def get do
    :persistent_term.get(@key, %{tables: %{}, relationships: %{}, functions: %{}})
  end

  @spec put(map()) :: :ok
  def put(cache), do: :persistent_term.put(@key, cache)

  @spec refresh() :: :ok
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl GenServer
  def init(opts) do
    conn = Keyword.get(opts, :conn, Postgrext.DB)
    schemas = Keyword.get(opts, :schemas, Postgrext.Config.get(:schemas))
    put(Postgrext.SchemaCache.Introspection.load(conn, schemas))
    {:ok, %{conn: conn, schemas: schemas}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    put(Postgrext.SchemaCache.Introspection.load(state.conn, state.schemas))
    {:reply, :ok, state}
  end
end
