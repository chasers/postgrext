defmodule Postgrext.Adapter do
  @moduledoc """
  Contract between the HTTP layer and a database backend.

  Adapters own SQL generation, execution, and transactions for their dialect,
  and normalize backend failures into `Postgrext.Error`. The controller only
  ever sees operation results: a JSON body already rendered by the database,
  the number of rows in it, and (for reads with `total: :exact`) the total
  count.

  Operation `opts`:

    * `:auth` — `%{role:, claims:}` from `Postgrext.Auth`; adapters apply it
      where the backend supports roles and ignore it otherwise
    * `:singular` — render a single JSON object instead of an array
    * `:returning` — `:representation` or `:minimal` for mutations
    * `:total` — `:exact` to compute the unlimited row count on reads
  """

  @type cache :: map()
  @type ast :: map()
  @type opts :: keyword()
  @type result :: %{
          body: String.t() | nil,
          count: non_neg_integer(),
          total: non_neg_integer() | nil
        }

  @callback children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  @callback introspect([String.t()]) :: cache()
  @callback default_schemas() :: [String.t()]
  @callback read(cache(), String.t(), String.t(), ast(), opts()) :: result()
  @callback insert(cache(), String.t(), String.t(), ast(), [map()], [String.t()], opts()) ::
              result()
  @callback update(cache(), String.t(), String.t(), ast(), map(), [String.t()], opts()) ::
              result()
  @callback delete(cache(), String.t(), String.t(), ast(), opts()) :: result()
  @callback rpc(cache(), String.t(), String.t(), ast(), map(), opts()) ::
              :void | {:scalar, String.t()} | {:rows, result()}
end
