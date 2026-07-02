defmodule Postgrext.SchemaCache do
  @moduledoc """
  Holds the introspected database structure in `:persistent_term` for fast
  lock-free reads. Loaded at startup via the configured adapter;
  `refresh/0` re-introspects on demand.
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
    adapter = Keyword.get(opts, :adapter, Postgrext.Config.adapter())
    schemas = Keyword.get(opts, :schemas, Postgrext.Config.get(:schemas))
    put(adapter.introspect(schemas))
    {:ok, %{adapter: adapter, schemas: schemas}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    put(state.adapter.introspect(state.schemas))
    {:reply, :ok, state}
  end
end
