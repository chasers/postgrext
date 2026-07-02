defmodule Postgrext.Request.Parser do
  @moduledoc """
  Parses a PostgREST-style query string into an adapter-neutral AST consumed by
  the adapter query builders.

  Produces a map with:

    * `:select` — nodes from `Postgrext.Request.Parser.Select`
    * `:filters` — list of `%{path:, tree:}` with trees from
      `Postgrext.Request.Parser.Filter`
    * `:order` — list of `%{path:, terms:}`
    * `:limit` / `:offset` — lists of `%{path:, value:}`
    * `:raw_params` — untouched key/value pairs (used for RPC args)

  A dotted key prefix scopes a parameter to an embedded resource:
  `clients.name=eq.acme`, `clients.order=name`, `clients.not.or=(...)`.
  """

  alias Postgrext.Error
  alias Postgrext.Request.Parser.Filter
  alias Postgrext.Request.Parser.Grammar
  alias Postgrext.Request.Parser.Select

  @ignored_keys ~w(columns on_conflict)

  @spec parse(String.t(), keyword()) :: map()
  def parse(query_string, opts \\ []) do
    skip_keys = Keyword.get(opts, :skip_keys, MapSet.new())
    pairs = decode_pairs(query_string)
    ast = new_ast(pairs)

    pairs
    |> Enum.reject(fn {key, _value} -> MapSet.member?(skip_keys, key) end)
    |> Enum.reduce(ast, &apply_param/2)
    |> Map.update!(:filters, &Enum.reverse/1)
    |> Map.update!(:order, &Enum.reverse/1)
  end

  defp new_ast(pairs) do
    %{select: [%{type: :all}], filters: [], order: [], limit: [], offset: [], raw_params: pairs}
  end

  defp apply_param({key, value}, ast) do
    case classify_key(key) do
      :select ->
        %{ast | select: Select.parse(value)}

      :ignored ->
        ast

      {:order, path} ->
        %{ast | order: [%{path: path, terms: parse_order(value)} | ast.order]}

      {:limit, path} ->
        %{ast | limit: [%{path: path, value: parse_nonneg_int(key, value)} | ast.limit]}

      {:offset, path} ->
        %{ast | offset: [%{path: path, value: parse_nonneg_int(key, value)} | ast.offset]}

      {:logic, op, negated, path} ->
        %{ast | filters: [%{path: path, tree: Filter.logic(op, negated, value)} | ast.filters]}

      {:filter, path, field} ->
        %{ast | filters: [%{path: path, tree: Filter.condition(field, value)} | ast.filters]}
    end
  end

  defp classify_key("select"), do: :select
  defp classify_key(key) when key in @ignored_keys, do: :ignored

  defp classify_key(key) do
    case key |> String.split(".") |> Enum.reverse() do
      ["order" | path] -> {:order, Enum.reverse(path)}
      ["limit" | path] -> {:limit, Enum.reverse(path)}
      ["offset" | path] -> {:offset, Enum.reverse(path)}
      [op, "not" | path] when op in ["and", "or"] -> {:logic, op, true, Enum.reverse(path)}
      [op | path] when op in ["and", "or"] -> {:logic, op, false, Enum.reverse(path)}
      [field | path] -> {:filter, Enum.reverse(path), field}
    end
  end

  defp decode_pairs(""), do: []

  defp decode_pairs(query_string) do
    query_string
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key] -> {URI.decode_www_form(key), ""}
        [key, value] -> {URI.decode_www_form(key), URI.decode_www_form(value)}
      end
    end)
  end

  defp parse_order(value) do
    case Grammar.order(value) do
      {:ok, terms, "", _context, _line, _offset} ->
        Enum.map(terms, &order_term/1)

      {:error, _reason, _rest, _context, _line, _offset} ->
        raise Error.parse_error("Could not parse order '#{value}'")
    end
  end

  defp order_term({:term, [field | modifiers]}) do
    Enum.reduce(modifiers, %{field: field, dir: nil, nulls: nil}, fn
      "asc", acc -> %{acc | dir: :asc}
      "desc", acc -> %{acc | dir: :desc}
      "nullsfirst", acc -> %{acc | nulls: :first}
      "nullslast", acc -> %{acc | nulls: :last}
      other, _acc -> raise Error.parse_error("Invalid order modifier '#{other}'")
    end)
  end

  defp parse_nonneg_int(key, value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _other -> raise Error.parse_error("Invalid value '#{value}' for '#{key}'")
    end
  end
end
