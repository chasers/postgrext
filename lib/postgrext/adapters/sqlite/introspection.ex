defmodule Postgrext.Adapters.SQLite.Introspection do
  @moduledoc """
  Builds the schema cache from `sqlite_master`, `pragma table_info`, and
  `pragma foreign_key_list`. Everything lives in the single "main" schema;
  SQLite has no stored functions, so the function cache is always empty.
  FK constraints have no names in SQLite, so hints match synthesized
  `<table>_<column>_fkey` names or column names.

  Row-level security state is read from the internal `postgrext_rls_enabled`
  and `postgrext_policies` tables into the cache; those two tables are never
  exposed as API relations.
  """

  alias Postgrext.Adapters.SQLite.Connection

  @schema "main"
  @internal_tables ["postgrext_rls_enabled", "postgrext_policies"]

  @spec load([String.t()]) :: map()
  def load(_schemas) do
    placeholders = Enum.map_join(@internal_tables, ", ", fn _name -> "?" end)

    relations =
      Connection.query!(
        "select name, type from sqlite_master where type in ('table','view') " <>
          "and name not like 'sqlite_%' and name not in (#{placeholders})",
        @internal_tables
      ).rows

    tables = Map.new(relations, fn [name, type] -> {{@schema, name}, table(name, type)} end)

    %{
      tables: tables,
      relationships: relationships(tables),
      functions: %{},
      rls_enabled: rls_enabled(),
      policies: policies()
    }
  end

  defp rls_enabled do
    Connection.query!("select table_name from postgrext_rls_enabled", []).rows
    |> MapSet.new(fn [name] -> {@schema, name} end)
  end

  defp policies do
    Connection.query!(
      "select table_name, name, command, kind, roles, using_expr, check_expr from postgrext_policies",
      []
    ).rows
    |> Enum.group_by(fn [table | _rest] -> {@schema, table} end, &policy/1)
  end

  defp policy([_table, name, command, kind, roles, using_expr, check_expr]) do
    %{
      name: name,
      command: String.upcase(command || "ALL"),
      kind: policy_kind(kind),
      roles: policy_roles(roles),
      using: using_expr,
      check: check_expr
    }
  end

  defp policy_kind(kind) do
    if String.upcase(kind || "PERMISSIVE") == "RESTRICTIVE", do: :restrictive, else: :permissive
  end

  defp policy_roles(nil), do: nil

  defp policy_roles(roles) do
    case Jason.decode(roles) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
      _other -> []
    end
  end

  defp table(name, type) do
    info = Connection.query!("pragma table_info(#{quote_ident(name)})", []).rows

    columns =
      Map.new(info, fn [_cid, column, decl_type, _notnull, _default, _pk] ->
        {column, decl_type || ""}
      end)

    %{
      schema: @schema,
      name: name,
      kind: if(type == "view", do: "v", else: "r"),
      columns: columns,
      column_order: Enum.map(info, fn [_cid, column | _rest] -> column end),
      pk: for([_cid, column, _type, _notnull, _default, pk] <- info, pk > 0, do: column)
    }
  end

  defp relationships(tables) do
    tables
    |> Enum.flat_map(fn {{_schema, name}, _table} -> foreign_keys(name, tables) end)
    |> Enum.group_by(fn {key, _rel} -> key end, fn {_key, rel} -> rel end)
  end

  defp foreign_keys(name, tables) do
    Connection.query!("pragma foreign_key_list(#{quote_ident(name)})", []).rows
    |> Enum.group_by(fn [id | _rest] -> id end)
    |> Enum.flat_map(fn {_id, rows} ->
      [[_id, _seq, target | _] | _] = rows
      from_cols = Enum.map(rows, fn [_id, _seq, _table, from, _to, _u, _d, _m] -> from end)

      to_cols =
        Enum.map(rows, fn [_id, _seq, _table, _from, to, _u, _d, _m] -> to end)
        |> resolve_target_columns(target, tables)

      constraint = "#{name}_#{Enum.join(from_cols, "_")}_fkey"

      m2o = %{
        cardinality: :m2o,
        constraint: constraint,
        table: {@schema, target},
        cols: from_cols,
        foreign_cols: to_cols
      }

      o2m = %{
        cardinality: :o2m,
        constraint: constraint,
        table: {@schema, name},
        cols: to_cols,
        foreign_cols: from_cols
      }

      [{{@schema, name}, m2o}, {{@schema, target}, o2m}]
    end)
  end

  defp resolve_target_columns(to_cols, target, tables) do
    if Enum.all?(to_cols, &is_binary/1) do
      to_cols
    else
      case Map.get(tables, {@schema, target}) do
        %{pk: pk} when length(pk) == length(to_cols) -> pk
        _other -> to_cols
      end
    end
  end

  defp quote_ident(name) do
    ~s("#{String.replace(name, ~s("), ~s(""))}")
  end
end
