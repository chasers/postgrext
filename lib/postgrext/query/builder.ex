defmodule Postgrext.Query.Builder do
  @moduledoc """
  Turns the parsed AST into parameterized SQL.

  All identifiers are validated against the schema cache and double-quoted;
  all values travel as text parameters cast in SQL to the column's introspected
  type (`($n::text)::integer`), so no user input is ever interpolated.

  Read queries are wrapped so Postgres itself produces the JSON body:

      with _source as (<query>)
      select coalesce(json_agg(_body), '[]')::text, count(*)::bigint
      from _source as _body

  Embedded resources become `left join lateral` subqueries aggregated with
  `to_json` (to-one) or `json_agg` (to-many), which supports arbitrary
  nesting depth.
  """

  alias Postgrext.Error

  @spec read(map(), String.t(), String.t(), map(), keyword()) :: {String.t(), [term()]}
  def read(cache, schema, relation, ast, opts \\ []) do
    table = fetch_table!(cache, schema, relation)
    {core, params} = relation_query(cache, table, relation, root_context(ast), [], nil, [])
    {wrap_json(core, Keyword.get(opts, :singular, false)), params}
  end

  @spec count(map(), String.t(), String.t(), map()) :: {String.t(), [term()]}
  def count(cache, schema, relation, ast) do
    table = fetch_table!(cache, schema, relation)
    {where_sql, params} = build_where(cache, table, relation, ast.filters, [], [])

    sql =
      "select count(*)::bigint from #{qualified(table)} as #{quote_ident(relation)}#{where_sql}"

    {sql, params}
  end

  @spec insert(map(), String.t(), String.t(), map(), String.t(), [String.t()], keyword()) ::
          {String.t(), [term()]}
  def insert(cache, schema, relation, ast, payload_json, columns, opts) do
    table = fetch_table!(cache, schema, relation)
    column_list = mutation_columns!(cache, table, relation, columns)

    base =
      "insert into #{qualified(table)} (#{column_list}) " <>
        "select #{column_list} from json_populate_recordset(null::#{qualified(table)}, ($1::text)::json) as _payload"

    wrap_mutation(cache, table, relation, ast, base, [payload_json], opts)
  end

  @spec update(map(), String.t(), String.t(), map(), String.t(), [String.t()], keyword()) ::
          {String.t(), [term()]}
  def update(cache, schema, relation, ast, payload_json, columns, opts) do
    table = fetch_table!(cache, schema, relation)
    column_list = mutation_columns!(cache, table, relation, columns)
    filters = require_filters!(ast, "UPDATE")

    {where_sql, params} = build_where(cache, table, relation, filters, [], [payload_json])

    base =
      "update #{qualified(table)} as #{quote_ident(relation)} " <>
        "set (#{column_list}) = " <>
        "(select #{column_list} from json_populate_record(null::#{qualified(table)}, ($1::text)::json))" <>
        where_sql

    wrap_mutation(cache, table, relation, ast, base, params, opts)
  end

  @spec delete(map(), String.t(), String.t(), map(), keyword()) :: {String.t(), [term()]}
  def delete(cache, schema, relation, ast, opts) do
    table = fetch_table!(cache, schema, relation)
    filters = require_filters!(ast, "DELETE")

    {where_sql, params} = build_where(cache, table, relation, filters, [], [])
    base = "delete from #{qualified(table)} as #{quote_ident(relation)}#{where_sql}"

    wrap_mutation(cache, table, relation, ast, base, params, opts)
  end

  @spec rpc(map(), String.t(), String.t(), map(), %{optional(String.t()) => term()}, keyword()) ::
          {String.t(), [term()], :void | :scalar | :rows}
  def rpc(cache, schema, fname, ast, args, opts \\ []) do
    fn_info =
      Map.get(cache.functions, {schema, fname}) || raise Error.undefined_function(fname)

    known_args = Map.new(fn_info.args)

    {arg_frags, params} =
      Enum.map_reduce(args, [], fn {name, value}, params ->
        type = Map.get(known_args, name) || raise Error.parse_error("Unknown argument '#{name}'")
        {ph, params} = placeholder(params, encode_arg(value, type))
        {"#{quote_ident(name)} := (#{ph}::text)::#{type}", params}
      end)

    call = "#{qualified({schema, fname})}(#{Enum.join(arg_frags, ", ")})"

    cond do
      fn_info.rettype == "void" ->
        {"select #{call}", params, :void}

      fn_info.returns_rows ->
        rpc_rows(cache, fname, ast, call, params, fn_info, opts)

      true ->
        {"select coalesce(to_json(#{call}), 'null')::text, 1::bigint", params, :scalar}
    end
  end

  defp rpc_rows(cache, fname, ast, call, params, fn_info, opts) do
    singular = Keyword.get(opts, :singular, false)

    case fn_info.rettype_relation && Map.get(cache.tables, fn_info.rettype_relation) do
      nil ->
        if root_filters(ast) != [] do
          raise Error.parse_error(
                  "Filters on functions without a table return type are not supported"
                )
        end

        {core, params} = untyped_rpc_query(fname, ast, call, params)
        {wrap_json(core, singular), params, :rows}

      table ->
        {core, params} = relation_query(cache, table, fname, root_context(ast), params, call, [])
        {wrap_json(core, singular), params, :rows}
    end
  end

  defp untyped_rpc_query(fname, ast, call, params) do
    order_terms = for %{path: [], terms: terms} <- ast.order, term <- terms, do: term

    order_sql =
      case order_terms do
        [] -> ""
        terms -> " order by " <> Enum.map_join(terms, ", ", &order_term_sql(fname, &1))
      end

    {limit_sql, offset_sql} = limit_offset_sql(ast)

    sql =
      "select #{quote_ident(fname)}.* from #{call} as #{quote_ident(fname)}" <>
        order_sql <> limit_sql <> offset_sql

    {sql, params}
  end

  defp wrap_mutation(cache, table, relation, ast, base, params, opts) do
    case Keyword.get(opts, :returning, :minimal) do
      :minimal ->
        {base, params}

      :representation ->
        mutated = "#{base} returning *"
        ctx = %{root_context(ast) | filters: [], order: [], limit: [], offset: []}
        {core, params} = relation_query(cache, table, relation, ctx, params, "_mutated", [])
        singular = Keyword.get(opts, :singular, false)

        body =
          if singular do
            "coalesce(json_agg(_body) -> 0, 'null')"
          else
            "coalesce(json_agg(_body), '[]')"
          end

        sql =
          "with _mutated as (#{mutated}), _source as (#{core}) " <>
            "select #{body}::text, count(*)::bigint from _source as _body"

        {sql, params}
    end
  end

  defp wrap_json(core, singular) do
    body =
      if singular do
        "coalesce(json_agg(_body) -> 0, 'null')"
      else
        "coalesce(json_agg(_body), '[]')"
      end

    "with _source as (#{core}) select #{body}::text, count(*)::bigint from _source as _body"
  end

  defp root_context(ast) do
    %{
      select: ast.select,
      filters: ast.filters,
      order: ast.order,
      limit: ast.limit,
      offset: ast.offset
    }
  end

  defp root_filters(ast), do: for(%{path: [], tree: tree} <- ast.filters, do: tree)

  defp require_filters!(ast, verb) do
    if root_filters(ast) == [] do
      raise Error.parse_error(
              "#{verb} requires at least one filter to avoid affecting the whole table"
            )
    end

    ast.filters
  end

  defp mutation_columns!(cache, table, relation, columns) do
    Enum.each(columns, &fetch_column_type!(cache, table, relation, &1))

    if columns == [] do
      raise Error.parse_error("Payload has no columns")
    end

    Enum.map_join(columns, ", ", &quote_ident/1)
  end

  defp relation_query(cache, table, alias_name, ctx, params, from_override, conditions) do
    {select_frags, joins, params} = build_select(cache, table, alias_name, ctx, params)
    {where_sql, params} = build_where(cache, table, alias_name, ctx.filters, conditions, params)
    order_sql = build_order(cache, table, alias_name, ctx.order)
    {limit_sql, offset_sql} = limit_offset_sql(ctx)
    from_sql = from_override || qualified(table)

    sql =
      "select #{Enum.join(select_frags, ", ")} from #{from_sql} as #{quote_ident(alias_name)}" <>
        Enum.join(joins) <> where_sql <> order_sql <> limit_sql <> offset_sql

    {sql, params}
  end

  defp build_select(cache, table, alias_name, ctx, params) do
    nodes = if ctx.select == [], do: [%{type: :all}], else: ctx.select

    {frags, {joins, params}} =
      Enum.map_reduce(nodes, {[], params}, fn node, {joins, params} ->
        case node do
          %{type: :all} ->
            {"#{quote_ident(alias_name)}.*", {joins, params}}

          %{type: :field} = field ->
            fetch_column_type!(cache, table, alias_name, field.name)
            {field_sql(alias_name, field), {joins, params}}

          %{type: :embed} = embed ->
            {frag, join, params} = build_embed(cache, table, alias_name, embed, ctx, params)
            {frag, {joins ++ [join], params}}
        end
      end)

    {frags, joins, params}
  end

  defp field_sql(alias_name, field) do
    base = "#{quote_ident(alias_name)}.#{quote_ident(field.name)}"
    cast = Enum.map_join(field.casts, "", &"::#{&1}")

    out_name =
      cond do
        field.alias -> field.alias
        field.casts != [] -> field.name
        true -> nil
      end

    base <> cast <> if(out_name, do: " as #{quote_ident(out_name)}", else: "")
  end

  defp build_embed(cache, table, alias_name, embed, ctx, params) do
    rel = resolve_relationship!(cache, table, embed)

    child_table =
      Map.get(cache.tables, rel.table) ||
        raise Error.undefined_relationship(table.name, embed.name)

    out_name = embed.alias || embed.name
    child_alias = "#{alias_name}_#{out_name}"
    join_alias = "#{child_alias}_j"

    join_conditions =
      Enum.zip(rel.cols, rel.foreign_cols)
      |> Enum.map(fn {mine, theirs} ->
        "#{quote_ident(child_alias)}.#{quote_ident(theirs)} = #{quote_ident(alias_name)}.#{quote_ident(mine)}"
      end)

    child_ctx = %{
      select: embed.select,
      filters: scoped(ctx.filters, embed),
      order: scoped(ctx.order, embed),
      limit: scoped(ctx.limit, embed),
      offset: scoped(ctx.offset, embed)
    }

    {inner_sql, params} =
      relation_query(cache, child_table, child_alias, child_ctx, params, nil, join_conditions)

    agg =
      case rel.cardinality do
        :m2o -> "to_json(_sub)"
        :o2m -> "coalesce(json_agg(_sub), '[]')"
      end

    join =
      " left join lateral (select #{agg} as _json from (#{inner_sql}) as _sub) as #{quote_ident(join_alias)} on true"

    frag = "#{quote_ident(join_alias)}._json as #{quote_ident(out_name)}"
    {frag, join, params}
  end

  defp scoped(entries, embed) do
    keys = Enum.reject([embed.name, embed.alias], &is_nil/1)

    entries
    |> Enum.filter(fn %{path: path} -> path != [] and hd(path) in keys end)
    |> Enum.map(fn entry -> %{entry | path: tl(entry.path)} end)
  end

  defp build_where(cache, table, alias_name, filters, extra_conditions, params) do
    trees = for %{path: [], tree: tree} <- filters, do: tree

    {condition_frags, params} =
      Enum.map_reduce(trees, params, fn tree, params ->
        condition_sql(cache, table, alias_name, tree, params)
      end)

    case extra_conditions ++ condition_frags do
      [] -> {"", params}
      conditions -> {" where " <> Enum.join(conditions, " and "), params}
    end
  end

  defp condition_sql(cache, table, alias_name, %{type: :logic} = logic, params) do
    {frags, params} =
      Enum.map_reduce(logic.children, params, fn child, params ->
        condition_sql(cache, table, alias_name, child, params)
      end)

    joiner = if logic.op == :and, do: " and ", else: " or "
    sql = "(#{Enum.join(frags, joiner)})"
    {if(logic.negated, do: "not #{sql}", else: sql), params}
  end

  defp condition_sql(cache, table, alias_name, %{type: :cond} = condition, params) do
    type = fetch_column_type!(cache, table, alias_name, condition.field)
    qcol = "#{quote_ident(alias_name)}.#{quote_ident(condition.field)}"
    operator_sql(qcol, type, condition, params)
  end

  defp operator_sql(qcol, _type, %{op: "is"} = condition, params) do
    verb = if condition.negated, do: "is not", else: "is"
    {"#{qcol} #{verb} #{condition.value}", params}
  end

  defp operator_sql(qcol, type, %{op: "in"} = condition, params) do
    {ph, params} = placeholder(params, condition.value)
    sql = "#{qcol} = any((#{ph}::text[])::#{array_type(type)})"
    {maybe_negate(sql, condition.negated), params}
  end

  defp operator_sql(qcol, _type, %{op: op} = condition, params)
       when op in ["like", "ilike"] do
    {ph, params} = placeholder(params, String.replace(condition.value, "*", "%"))
    {maybe_negate("#{qcol} #{op} (#{ph}::text)", condition.negated), params}
  end

  defp operator_sql(qcol, _type, %{op: op} = condition, params)
       when op in ["match", "imatch"] do
    operator = if op == "match", do: "~", else: "~*"
    {ph, params} = placeholder(params, condition.value)
    {maybe_negate("#{qcol} #{operator} (#{ph}::text)", condition.negated), params}
  end

  defp operator_sql(qcol, _type, %{op: op} = condition, params)
       when op in ["fts", "plfts", "phfts", "wfts"] do
    fun =
      case op do
        "fts" -> "to_tsquery"
        "plfts" -> "plainto_tsquery"
        "phfts" -> "phraseto_tsquery"
        "wfts" -> "websearch_to_tsquery"
      end

    {ph, params} = placeholder(params, condition.value)

    {query, params} =
      case condition.lang do
        lang when lang in [nil, ""] ->
          {"#{fun}((#{ph}::text))", params}

        lang ->
          {lang_ph, params} = placeholder(params, lang)
          {"#{fun}((#{lang_ph}::text)::regconfig, (#{ph}::text))", params}
      end

    {maybe_negate("#{qcol} @@ #{query}", condition.negated), params}
  end

  defp operator_sql(qcol, type, condition, params) do
    operator =
      case condition.op do
        "eq" -> "="
        "neq" -> "<>"
        "ne" -> "<>"
        "gt" -> ">"
        "gte" -> ">="
        "lt" -> "<"
        "lte" -> "<="
        "cs" -> "@>"
        "cd" -> "<@"
        "ov" -> "&&"
        "sl" -> "<<"
        "sr" -> ">>"
        "nxr" -> "&<"
        "nxl" -> "&>"
        "adj" -> "-|-"
      end

    {ph, params} = placeholder(params, condition.value)
    sql = "#{qcol} #{operator} ((#{ph}::text)::#{type})"
    {maybe_negate(sql, condition.negated), params}
  end

  defp maybe_negate(sql, true), do: "not (#{sql})"
  defp maybe_negate(sql, false), do: sql

  defp build_order(_cache, _table, _alias_name, []), do: ""

  defp build_order(cache, table, alias_name, order_entries) do
    terms = for %{path: [], terms: terms} <- order_entries, term <- terms, do: term

    case terms do
      [] ->
        ""

      terms ->
        Enum.each(terms, &fetch_column_type!(cache, table, alias_name, &1.field))
        " order by " <> Enum.map_join(terms, ", ", &order_term_sql(alias_name, &1))
    end
  end

  defp order_term_sql(alias_name, term) do
    dir =
      case term.dir do
        :asc -> " asc"
        :desc -> " desc"
        nil -> ""
      end

    nulls =
      case term.nulls do
        :first -> " nulls first"
        :last -> " nulls last"
        nil -> ""
      end

    "#{quote_ident(alias_name)}.#{quote_ident(term.field)}#{dir}#{nulls}"
  end

  defp limit_offset_sql(ctx) do
    limit = Enum.find_value(ctx.limit, fn %{path: p, value: v} -> if p == [], do: v end)
    offset = Enum.find_value(ctx.offset, fn %{path: p, value: v} -> if p == [], do: v end)

    {if(limit, do: " limit #{limit}", else: ""), if(offset, do: " offset #{offset}", else: "")}
  end

  defp resolve_relationship!(cache, table, embed) do
    candidates =
      cache.relationships
      |> Map.get({table.schema, table.name}, [])
      |> Enum.filter(fn rel -> elem(rel.table, 1) == embed.name end)
      |> filter_by_hint(embed.hint)

    case candidates do
      [rel] -> rel
      [] -> raise Error.undefined_relationship(table.name, embed.name)
      _many -> raise Error.ambiguous_relationship(table.name, embed.name)
    end
  end

  defp filter_by_hint(candidates, nil), do: candidates

  defp filter_by_hint(candidates, hint) do
    Enum.filter(candidates, fn rel ->
      rel.constraint == hint or hint in rel.cols or hint in rel.foreign_cols
    end)
  end

  defp fetch_table!(cache, schema, relation) do
    Map.get(cache.tables, {schema, relation}) || raise Error.undefined_relation(relation)
  end

  defp fetch_column_type!(_cache, table, relation_label, column) do
    Map.get(table.columns, column) || raise Error.undefined_column(relation_label, column)
  end

  defp encode_arg(value, type) do
    cond do
      is_binary(value) ->
        value

      is_nil(value) ->
        nil

      is_number(value) or is_boolean(value) ->
        to_string(value)

      is_list(value) or is_map(value) ->
        if String.starts_with?(type, "json") do
          Jason.encode!(value)
        else
          raise Error.parse_error("Unsupported argument value for type '#{type}'")
        end
    end
  end

  defp array_type(type) do
    if String.ends_with?(type, "[]"), do: type, else: type <> "[]"
  end

  defp placeholder(params, value) do
    params = params ++ [value]
    {"$#{length(params)}", params}
  end

  defp qualified(%{schema: schema, name: name}), do: qualified({schema, name})

  defp qualified({schema, name}) do
    ~s("#{escape_ident(schema)}"."#{escape_ident(name)}")
  end

  defp quote_ident(name) do
    ~s("#{escape_ident(name)}")
  end

  defp escape_ident(name), do: String.replace(name, ~s("), ~s(""))
end
