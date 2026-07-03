defmodule Postgrext.Adapters.SQLite do
  @moduledoc """
  SQLite backend on `exqlite`, selected with `PGRST_DB_URI=sqlite:<path>`
  (or `sqlite::memory:`).

  Differences from the PostgreSQL backend: there is a single "main" schema
  and no stored functions (RPC 404s). There are no database roles, but
  row-level security is emulated: policies stored in `postgrext_policies`
  (see `Postgrext.Adapters.SQLite.Policies`) filter reads, updates, and
  deletes, and `WITH CHECK` expressions are enforced by re-checking the
  affected rows inside the transaction — a violation rolls back with 403.
  The JWT `role` claim selects which policies apply.

  Representation mutations re-read the affected rows by rowid inside the
  transaction, so `WITHOUT ROWID` tables only support
  `Prefer: return=minimal` (and no RLS check enforcement). Deletes with
  `return=representation` read the matching rows before deleting.
  """

  @behaviour Postgrext.Adapter

  alias Postgrext.Adapters.SQLite.Builder
  alias Postgrext.Adapters.SQLite.Connection
  alias Postgrext.Adapters.SQLite.Introspection
  alias Postgrext.Adapters.SQLite.Policies
  alias Postgrext.Error

  @impl Postgrext.Adapter
  def children(config) do
    [{Connection, database: config[:db_path]}]
  end

  @impl Postgrext.Adapter
  def introspect(schemas) do
    Introspection.load(schemas)
  end

  @impl Postgrext.Adapter
  def default_schemas, do: ["main"]

  @impl Postgrext.Adapter
  def read(cache, schema, relation, ast, opts) do
    {sql, params} =
      Builder.read(cache, schema, relation, ast, singular: opts[:singular], auth: opts[:auth])

    count_query =
      if opts[:total] == :exact do
        Builder.count(cache, schema, relation, ast, auth: opts[:auth])
      end

    Connection.transaction(fn db ->
      [[body, count]] = Connection.query!(db, sql, params).rows

      total =
        case count_query do
          nil -> nil
          {count_sql, count_params} -> hd(hd(Connection.query!(db, count_sql, count_params).rows))
        end

      %{body: body, count: count, total: total}
    end)
  end

  @impl Postgrext.Adapter
  def insert(cache, schema, relation, ast, rows, columns, opts) do
    representation = opts[:returning] == :representation
    check = check_condition(cache, schema, relation, opts, "INSERT")

    {sql, _params} =
      Builder.insert(cache, schema, relation, columns,
        returning_rowids: representation or check != nil
      )

    Connection.transaction(fn db ->
      result = Connection.query!(db, sql, [Jason.encode!(rows)])
      enforce_check!(db, relation, result, check)
      mutation_result(cache, schema, relation, ast, db, result, opts)
    end)
  end

  @impl Postgrext.Adapter
  def update(cache, schema, relation, ast, payload, columns, opts) do
    representation = opts[:returning] == :representation
    check = check_condition(cache, schema, relation, opts, "UPDATE")

    {sql, params} =
      Builder.update(cache, schema, relation, ast, Jason.encode!(payload), columns,
        returning_rowids: representation or check != nil,
        auth: opts[:auth]
      )

    Connection.transaction(fn db ->
      result = Connection.query!(db, sql, params)
      enforce_check!(db, relation, result, check)
      mutation_result(cache, schema, relation, ast, db, result, opts)
    end)
  end

  @impl Postgrext.Adapter
  def delete(cache, schema, relation, ast, opts) do
    {sql, params} = Builder.delete(cache, schema, relation, ast, auth: opts[:auth])

    Connection.transaction(fn db ->
      representation =
        if opts[:returning] == :representation do
          rep_ast = %{ast | order: [], limit: [], offset: []}

          read_page(cache, schema, relation, rep_ast, db,
            singular: opts[:singular],
            auth: opts[:auth]
          )
        end

      result = Connection.query!(db, sql, params)

      case representation do
        nil -> %{body: nil, count: result.changes, total: nil}
        page -> page
      end
    end)
  end

  @impl Postgrext.Adapter
  def rpc(_cache, _schema, fname, _ast, _args, _opts) do
    raise Error.undefined_function(fname)
  end

  defp mutation_result(cache, schema, relation, ast, db, result, opts) do
    if opts[:returning] == :representation do
      rowids = List.flatten(result.rows)
      rep_ast = %{ast | filters: [], order: [], limit: [], offset: []}

      read_page(cache, schema, relation, rep_ast, db,
        singular: opts[:singular],
        rowids: rowids,
        auth: opts[:auth]
      )
    else
      %{body: nil, count: result.changes, total: nil}
    end
  end

  defp check_condition(cache, schema, relation, opts, command) do
    case Map.get(cache.tables, {schema, relation}) do
      nil -> nil
      table -> Policies.check(cache, opts[:auth], table, command)
    end
  end

  defp enforce_check!(_db, _relation, _result, nil), do: :ok

  defp enforce_check!(db, relation, result, check) do
    case List.flatten(result.rows) do
      [] ->
        :ok

      rowids ->
        {sql, params} = Policies.violation_query(relation, rowids, check)
        [[violations]] = Connection.query!(db, sql, params).rows

        if violations > 0 do
          raise Error.rls_violation(relation)
        end

        :ok
    end
  end

  defp read_page(cache, schema, relation, ast, db, opts) do
    {sql, params} = Builder.read(cache, schema, relation, ast, opts)
    [[body, count]] = Connection.query!(db, sql, params).rows
    %{body: body, count: count, total: nil}
  end
end
