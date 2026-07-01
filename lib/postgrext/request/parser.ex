defmodule Postgrext.Request.Parser do
  @moduledoc """
  Parses a PostgREST-style query string into an AST consumed by
  `Postgrext.Query.Builder`.

  Produces a map with:

    * `:select` — list of nodes: `%{type: :all}`,
      `%{type: :field, name:, alias:, casts:}`, or
      `%{type: :embed, name:, alias:, hint:, select:}`
    * `:filters` — list of `%{path:, tree:}` where tree is a
      `%{type: :cond, ...}` or `%{type: :logic, op:, negated:, children:}`
    * `:order` — list of `%{path:, terms:}`
    * `:limit` / `:offset` — lists of `%{path:, value:}`
    * `:raw_params` — untouched key/value pairs (used for RPC args)
  """

  alias Postgrext.Error

  @simple_ops ~w(eq neq ne gt gte lt lte like ilike match imatch is in cs cd ov sl sr nxr nxl adj)
  @fts_ops ~w(fts plfts phfts wfts)
  @ops @simple_ops ++ @fts_ops
  @reserved_keys ~w(select order limit offset and or columns on_conflict)

  @spec parse(String.t(), keyword()) :: map()
  def parse(query_string, opts \\ []) do
    skip_keys = Keyword.get(opts, :skip_keys, MapSet.new())
    pairs = decode_pairs(query_string)

    Enum.reduce(pairs, empty_ast(pairs), fn {key, value}, ast ->
      if MapSet.member?(skip_keys, key) do
        ast
      else
        classify(ast, split_key(key), key, value)
      end
    end)
    |> Map.update!(:filters, &Enum.reverse/1)
    |> Map.update!(:order, &Enum.reverse/1)
  end

  defp empty_ast(pairs) do
    %{select: [%{type: :all}], filters: [], order: [], limit: [], offset: [], raw_params: pairs}
  end

  defp classify(ast, ["select"], _key, value),
    do: %{ast | select: parse_select(value)}

  defp classify(ast, path_and_verb, key, value) do
    case Enum.split(path_and_verb, -1) do
      {path, ["order"]} ->
        %{ast | order: [%{path: path, terms: parse_order(value)} | ast.order]}

      {path, ["limit"]} ->
        %{ast | limit: [%{path: path, value: parse_nonneg_int(key, value)} | ast.limit]}

      {path, ["offset"]} ->
        %{ast | offset: [%{path: path, value: parse_nonneg_int(key, value)} | ast.offset]}

      {path, [logic]} when logic in ["and", "or"] ->
        tree = parse_logic(logic, false, value)
        %{ast | filters: [%{path: path, tree: tree} | ast.filters]}

      {path, ["not"]} ->
        raise Error.parse_error("Unexpected key '#{Enum.join(path ++ ["not"], ".")}'")

      _other ->
        classify_filter(ast, path_and_verb, key, value)
    end
  end

  defp classify_filter(ast, segments, key, value) do
    if key in @reserved_keys do
      ast
    else
      {path, [field]} = Enum.split(segments, -1)
      condition = parse_condition(field, value)
      %{ast | filters: [%{path: path, tree: condition} | ast.filters]}
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

  defp split_key(key), do: String.split(key, ".")

  @doc false
  @spec parse_select(String.t()) :: [map()]
  def parse_select(""), do: [%{type: :all}]

  def parse_select(value) do
    {items, rest} = parse_select_items(value, [])

    if rest != "" do
      raise Error.parse_error("Unexpected '#{rest}' in select parameter")
    end

    items
  end

  defp parse_select_items(input, acc) do
    {item, rest} = parse_select_item(input)
    acc = [item | acc]

    case rest do
      "," <> more -> parse_select_items(more, acc)
      _other -> {Enum.reverse(acc), rest}
    end
  end

  defp parse_select_item(input) do
    {token, rest} = take_until(input, [",", "(", ")"])

    case rest do
      "(" <> inner ->
        {children, inner_rest} = parse_select_items(inner, [])

        case inner_rest do
          ")" <> more -> {build_embed(token, children), more}
          _other -> raise Error.parse_error("Unclosed embed in select parameter")
        end

      _other ->
        {build_field(token), rest}
    end
  end

  defp take_until(input, stops), do: take_until(input, stops, "")

  defp take_until("", _stops, acc), do: {acc, ""}

  defp take_until(<<char::utf8, rest::binary>> = input, stops, acc) do
    if <<char::utf8>> in stops do
      {acc, input}
    else
      take_until(rest, stops, acc <> <<char::utf8>>)
    end
  end

  defp build_field("*"), do: %{type: :all}

  defp build_field(token) do
    {alias_name, token} = split_alias(token)

    case String.split(token, "::") do
      [""] ->
        raise Error.parse_error("Empty column name in select parameter")

      [name | casts] ->
        Enum.each(casts, &validate_cast/1)
        %{type: :field, name: name, alias: alias_name, casts: casts}
    end
  end

  defp build_embed(token, children) do
    {alias_name, token} = split_alias(token)

    {name, hint} =
      case String.split(token, "!", parts: 2) do
        [name] -> {name, nil}
        [name, hint] -> {name, hint}
      end

    if name == "" do
      raise Error.parse_error("Empty embed name in select parameter")
    end

    %{type: :embed, name: name, alias: alias_name, hint: hint, select: children}
  end

  defp split_alias(token) do
    case Regex.run(~r/\A([^:]+):(?!:)(.+)\z/s, token) do
      [_all, alias_name, rest] -> {alias_name, rest}
      nil -> {nil, token}
    end
  end

  defp validate_cast(cast) do
    unless Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_ ]*(\(\d+(,\d+)?\))?(\[\])?\z/, cast) do
      raise Error.parse_error("Invalid cast '#{cast}' in select parameter")
    end
  end

  @doc false
  @spec parse_condition(String.t(), String.t()) :: map()
  def parse_condition(field, value) do
    {negated, rest} =
      case value do
        "not." <> rest -> {true, rest}
        rest -> {false, rest}
      end

    {op, lang, raw_value} = split_op(rest)
    build_condition(field, negated, op, lang, raw_value)
  end

  defp split_op(input) do
    case String.split(input, ".", parts: 2) do
      [op_token, raw_value] ->
        {op, lang} = parse_op_token(op_token)
        {op, lang, raw_value}

      [op_token] ->
        {op, lang} = parse_op_token(op_token)
        {op, lang, ""}
    end
  end

  defp parse_op_token(token) do
    case Regex.run(~r/\A([a-z]+)\(([^)]*)\)\z/, token) do
      [_all, op, lang] when op in @fts_ops -> {op, lang}
      nil when token in @ops -> {token, nil}
      _other -> raise Error.parse_error("Unknown filter operator '#{token}'")
    end
  end

  defp build_condition(field, negated, "in", _lang, raw_value) do
    %{
      type: :cond,
      field: field,
      op: "in",
      negated: negated,
      lang: nil,
      value: parse_list(raw_value)
    }
  end

  defp build_condition(field, negated, "is", _lang, raw_value) do
    unless raw_value in ~w(null true false unknown) do
      raise Error.parse_error("Invalid value '#{raw_value}' for `is` operator")
    end

    %{type: :cond, field: field, op: "is", negated: negated, lang: nil, value: raw_value}
  end

  defp build_condition(field, negated, op, lang, raw_value) do
    %{
      type: :cond,
      field: field,
      op: op,
      negated: negated,
      lang: lang,
      value: unquote_value(raw_value)
    }
  end

  defp parse_list(raw) do
    case Regex.run(~r/\A\((.*)\)\z/s, raw) do
      [_all, inner] ->
        inner
        |> split_top_level()
        |> Enum.map(&unquote_value(String.trim(&1)))

      nil ->
        raise Error.parse_error("`in` operator requires a parenthesized list")
    end
  end

  defp unquote_value(value) do
    case Regex.run(~r/\A"(.*)"\z/s, value) do
      [_all, inner] -> String.replace(inner, ~r/\\(.)/, "\\1")
      nil -> value
    end
  end

  @doc false
  @spec parse_logic(String.t(), boolean(), String.t()) :: map()
  def parse_logic(op, negated, value) do
    inner =
      case Regex.run(~r/\A\((.*)\)\z/s, value) do
        [_all, inner] -> inner
        nil -> raise Error.parse_error("`#{op}` requires a parenthesized list of conditions")
      end

    children =
      inner
      |> split_top_level()
      |> Enum.map(&parse_logic_element/1)

    if children == [] do
      raise Error.parse_error("`#{op}` requires at least one condition")
    end

    %{type: :logic, op: String.to_existing_atom(op), negated: negated, children: children}
  end

  defp parse_logic_element(element) do
    element = String.trim(element)

    cond do
      match = Regex.run(~r/\A(not\.)?(and|or)(\(.*\))\z/s, element) ->
        [_all, not_part, op, rest] = match
        parse_logic(op, not_part != "", rest)

      true ->
        parse_logic_condition(element)
    end
  end

  defp parse_logic_condition(element) do
    segments = split_top_level(element, ".")

    op_index =
      Enum.find_index(segments, fn segment ->
        segment in @ops or segment == "not" or Regex.match?(~r/\A[a-z]+\(.*\)\z/, segment)
      end)

    case op_index do
      nil ->
        raise Error.parse_error("Could not parse logic condition '#{element}'")

      0 ->
        raise Error.parse_error("Missing field in logic condition '#{element}'")

      index ->
        field = segments |> Enum.take(index) |> Enum.join(".")
        value = segments |> Enum.drop(index) |> Enum.join(".")
        parse_condition(field, value)
    end
  end

  @doc false
  @spec parse_order(String.t()) :: [map()]
  def parse_order(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&parse_order_term/1)
    |> case do
      [] -> raise Error.parse_error("Empty order parameter")
      terms -> terms
    end
  end

  defp parse_order_term(term) do
    [field | modifiers] = String.split(String.trim(term), ".")

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

  defp split_top_level(input, separator \\ ",") do
    split_top_level(input, separator, 0, false, "", [])
  end

  defp split_top_level("", _sep, _depth, _quoted, current, acc) do
    Enum.reverse([current | acc])
  end

  defp split_top_level(<<"\\", char::utf8, rest::binary>>, sep, depth, true, current, acc) do
    split_top_level(rest, sep, depth, true, current <> "\\" <> <<char::utf8>>, acc)
  end

  defp split_top_level(<<"\"", rest::binary>>, sep, depth, quoted, current, acc) do
    split_top_level(rest, sep, depth, not quoted, current <> "\"", acc)
  end

  defp split_top_level(<<char::utf8, rest::binary>>, sep, depth, false, current, acc) do
    char_str = <<char::utf8>>

    cond do
      char_str == "(" ->
        split_top_level(rest, sep, depth + 1, false, current <> char_str, acc)

      char_str == ")" ->
        split_top_level(rest, sep, max(depth - 1, 0), false, current <> char_str, acc)

      char_str == sep and depth == 0 ->
        split_top_level(rest, sep, depth, false, "", [current | acc])

      true ->
        split_top_level(rest, sep, depth, false, current <> char_str, acc)
    end
  end

  defp split_top_level(<<char::utf8, rest::binary>>, sep, depth, true, current, acc) do
    split_top_level(rest, sep, depth, true, current <> <<char::utf8>>, acc)
  end
end
