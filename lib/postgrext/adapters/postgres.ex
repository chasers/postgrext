defmodule Postgrext.Adapters.Postgres do
  @moduledoc """
  PostgreSQL backend: Postgrex pool, pg_catalog introspection, and the
  PostgreSQL dialect of `Postgrext.Adapters.Postgres.Builder`.

  Every operation runs in a transaction with the request role applied via
  `set_config('role', ...)` and the JWT claims exposed as
  `request.jwt.claims`, so row-level security behaves as under PostgREST.
  """

  @behaviour Postgrext.Adapter

  alias Postgrext.Adapters.Postgres.Builder
  alias Postgrext.Adapters.Postgres.Introspection
  alias Postgrext.Error

  @impl Postgrext.Adapter
  def children(config) do
    [
      {Postgrex,
       [name: Postgrext.DB, pool_size: config[:pool_size]] ++
         Postgrext.Config.db_opts(config[:db_uri])}
    ]
  end

  @impl Postgrext.Adapter
  def introspect(schemas) do
    Introspection.load(Postgrext.DB, schemas)
  end

  @impl Postgrext.Adapter
  def default_schemas, do: ["public"]

  @impl Postgrext.Adapter
  def read(cache, schema, relation, ast, opts) do
    {sql, params} = Builder.read(cache, schema, relation, ast, singular: opts[:singular])

    count_query =
      if opts[:total] == :exact do
        Builder.count(cache, schema, relation, ast)
      end

    transact(opts[:auth], fn conn ->
      [[body, count]] = Postgrex.query!(conn, sql, params).rows

      total =
        case count_query do
          nil -> nil
          {count_sql, count_params} -> hd(hd(Postgrex.query!(conn, count_sql, count_params).rows))
        end

      %{body: body, count: count, total: total}
    end)
  end

  @impl Postgrext.Adapter
  def insert(cache, schema, relation, ast, rows, columns, opts) do
    {sql, params} =
      Builder.insert(cache, schema, relation, ast, Jason.encode!(rows), columns,
        returning: opts[:returning],
        singular: opts[:singular]
      )

    mutate(opts, sql, params)
  end

  @impl Postgrext.Adapter
  def update(cache, schema, relation, ast, payload, columns, opts) do
    {sql, params} =
      Builder.update(cache, schema, relation, ast, Jason.encode!(payload), columns,
        returning: opts[:returning],
        singular: opts[:singular]
      )

    mutate(opts, sql, params)
  end

  @impl Postgrext.Adapter
  def delete(cache, schema, relation, ast, opts) do
    {sql, params} =
      Builder.delete(cache, schema, relation, ast,
        returning: opts[:returning],
        singular: opts[:singular]
      )

    mutate(opts, sql, params)
  end

  @impl Postgrext.Adapter
  def rpc(cache, schema, fname, ast, args, opts) do
    {sql, params, kind} =
      Builder.rpc(cache, schema, fname, ast, args, singular: opts[:singular])

    result = transact(opts[:auth], fn conn -> Postgrex.query!(conn, sql, params) end)

    case kind do
      :void -> :void
      :scalar -> {:scalar, result.rows |> hd() |> hd()}
      :rows -> {:rows, wrap_rows(result)}
    end
  end

  defp mutate(opts, sql, params) do
    result = transact(opts[:auth], fn conn -> Postgrex.query!(conn, sql, params) end)

    case opts[:returning] do
      :representation -> wrap_rows(result)
      _minimal -> %{body: nil, count: result.num_rows, total: nil}
    end
  end

  defp wrap_rows(%{rows: [[body, count]]}) do
    %{body: body, count: count, total: nil}
  end

  defp transact(auth, fun) do
    result =
      Postgrex.transaction(Postgrext.DB, fn conn ->
        apply_role(conn, auth)
        fun.(conn)
      end)

    case result do
      {:ok, value} ->
        value

      {:error, :rollback} ->
        raise %Error{status: 500, code: "PGRST000", message: "transaction rolled back"}
    end
  end

  defp apply_role(_conn, nil), do: :ok
  defp apply_role(_conn, %{role: nil}), do: :ok

  defp apply_role(conn, %{role: role, claims: claims}) do
    Postgrex.query!(
      conn,
      "select set_config('role', $1, true), set_config('request.jwt.claims', $2, true)",
      [role, Jason.encode!(claims)]
    )
  end
end
