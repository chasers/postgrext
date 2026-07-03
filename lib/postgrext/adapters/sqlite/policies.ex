defmodule Postgrext.Adapters.SQLite.Policies do
  @moduledoc """
  Row-level security for the SQLite backend.

  Policies live in the `postgrext_policies` table (with per-table enablement
  in `postgrext_rls_enabled`) and are loaded into the schema cache by
  introspection. Each row maps 1:1 onto a PostgreSQL `CREATE POLICY`
  statement, so a database can be upgraded to native Postgres policies
  mechanically; nothing needs to translate back.

  `using_expr` / `check_expr` are SQL boolean expressions over the table's
  columns. The request auth context is available through `auth.role()`,
  `auth.uid()` (the JWT `sub` claim), and `auth.jwt()` (the claims as JSON
  text, combine with `->>`), which are rewritten into bound parameters before
  execution — on Postgres they resolve to the standard Supabase `auth`
  helper functions instead.

  Semantics follow PostgreSQL: with RLS enabled and no applicable policy the
  table is inaccessible; permissive policies OR together and restrictive
  policies AND on top; a policy applies when its command is `ALL` or matches
  the statement and its role list is null (PUBLIC) or contains the request
  role; a missing `check_expr` falls back to `using_expr`.
  """

  @type condition :: {String.t(), [term()]}

  @auth_functions ~r/auth\.(?:role|uid|jwt)\(\)/

  @spec visibility(map(), map() | nil, map(), String.t()) :: condition() | nil
  def visibility(cache, auth, table, command) do
    combine(cache, auth, table, command, & &1.using)
  end

  @spec check(map(), map() | nil, map(), String.t()) :: condition() | nil
  def check(cache, auth, table, command) do
    combine(cache, auth, table, command, &(&1.check || &1.using))
  end

  @spec violation_query(String.t(), [integer()], condition()) :: {String.t(), [term()]}
  def violation_query(relation, rowids, {check_sql, check_params}) do
    placeholders = Enum.map_join(rowids, ", ", fn _rowid -> "?" end)

    sql =
      "select count(*) from #{quote_ident(relation)} as #{quote_ident(relation)} " <>
        "where #{quote_ident(relation)}.\"rowid\" in (#{placeholders}) " <>
        "and not coalesce((#{check_sql}), 0)"

    {sql, rowids ++ check_params}
  end

  defp combine(cache, auth, table, command, extract) do
    if enabled?(cache, table) do
      auth = auth || %{role: nil, claims: %{}}

      {permissive, restrictive} =
        cache
        |> Map.get(:policies, %{})
        |> Map.get({table.schema, table.name}, [])
        |> Enum.filter(&applies?(&1, command, auth.role))
        |> Enum.split_with(&(&1.kind == :permissive))

      permissive
      |> Enum.flat_map(&List.wrap(extract.(&1)))
      |> permissive_sql()
      |> restrict(Enum.flat_map(restrictive, &List.wrap(extract.(&1))))
      |> rewrite(auth)
    end
  end

  defp enabled?(cache, table) do
    cache
    |> Map.get(:rls_enabled, MapSet.new())
    |> MapSet.member?({table.schema, table.name})
  end

  defp applies?(policy, command, role) do
    policy.command in ["ALL", command] and role_applies?(policy.roles, role)
  end

  defp role_applies?(nil, _role), do: true
  defp role_applies?(roles, role), do: role != nil and role in roles

  defp permissive_sql([]), do: "0"
  defp permissive_sql(exprs), do: "(" <> Enum.map_join(exprs, " or ", &"(#{&1})") <> ")"

  defp restrict(sql, []), do: sql

  defp restrict(sql, exprs) do
    Enum.join([sql | Enum.map(exprs, &"(#{&1})")], " and ")
  end

  defp rewrite(expr, auth) do
    {parts, params} =
      @auth_functions
      |> Regex.split(expr, include_captures: true)
      |> Enum.map_reduce([], fn part, params ->
        case auth_value(part, auth) do
          :static -> {part, params}
          {:param, value} -> {"?", params ++ [value]}
        end
      end)

    {Enum.join(parts), params}
  end

  defp auth_value("auth.role()", auth), do: {:param, auth.role}
  defp auth_value("auth.uid()", auth), do: {:param, Map.get(auth.claims, "sub")}
  defp auth_value("auth.jwt()", auth), do: {:param, Jason.encode!(auth.claims)}
  defp auth_value(_part, _auth), do: :static

  defp quote_ident(name) do
    ~s("#{String.replace(name, ~s("), ~s(""))}")
  end
end
