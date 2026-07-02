defmodule Postgrext.Adapters.SQLite.Builder do
  @moduledoc """
  SQLite dialect of the query builder.

  Rows are rendered as JSON by SQLite itself: each row becomes a
  `json_object(...)` (with `*` expanded to the cached column list, since
  SQLite has no row-to-JSON shortcut) and pages aggregate with
  `json_group_array`. Embeds are correlated subqueries instead of lateral
  joins. Parameters are positional `?` and rely on column affinity, so no
  type casts are needed. Operators without a SQLite equivalent (full text
  search, regex matches, array/range containment) raise a 400.

  Boolean-declared columns are rendered as JSON `true`/`false` rather than
  SQLite's 0/1 storage form.
  """

  alias Postgrext.Error

  @operators %{
    "eq" => "=",
    "neq" => "<>",
    "ne" => "<>",
    "gt" => ">",
    "gte" => ">=",
    "lt" => "<",
    "lte" => "<="
  }

  @unsupported_ops ~w(match imatch cs cd ov sl sr nxr nxl adj fts plfts phfts wfts)

  @spec read(map(), String.t(), String.t(), map(), keyword()) :: {String.t(), [term()]}
  def read(cache, schema, relation, ast, opts \\ []) do
    table = fetch_table!(cache, schema, relation)

    extra =
      case Keyword.get(opts, :rowids) do
        nil -> []
        rowids -> [rowid_condition(relation, rowids)]
      end

    {extra_conditions, params} =
      Enum.map_reduce(extra, [], fn {sql, values}, params -> {sql, params ++ values} end)

    {inner, params} =
      row_query(cache, table, relation, root_context(ast), params, extra_conditions)

    body =
      if Keyword.get(opts, :singular, false) do
        "coalesce(json_extract(json_group_array(json(js)), '$[0]'), 'null')"
      else
        "coalesce(json_group_array(json(js)), '[]')"
      end

    {"select #{body}, count(*) from (#{inner}) as _body", params}
  end

  @spec count(map(), String.t(), String.t(), map()) :: {String.t(), [term()]}
  def count(cache, schema, relation, ast) do
    table = fetch_table!(cache, schema, relation)
    {where_sql, params} = build_where(cache, table, relation, ast.filters, [], [])

    {"select count(*) from #{quote_ident(relation)} as #{quote_ident(relation)}#{where_sql}",
     params}
  end

  @spec insert(map(), String.t(), String.t(), [String.t()], keyword()) :: {String.t(), [term()]}
  def insert(cache, schema, relation, columns, opts) do
    table = fetch_table!(cache, schema, relation)
    validate_columns!(table, relation, columns)

    column_list = Enum.map_join(columns, ", ", &quote_ident/1)
    extracts = Enum.map_join(columns, ", ", &"json_extract(value, #{json_path(&1)})")

    sql =
      "insert into #{quote_ident(relation)} (#{column_list}) " <>
        "select #{extracts} from json_each(?)" <> returning(opts)

    {sql, []}
  end

  @spec update(map(), String.t(), String.t(), map(), String.t(), [String.t()], keyword()) ::
          {String.t(), [term()]}
  def update(cache, schema, relation, ast, payload_json, columns, opts) do
    table = fetch_table!(cache, schema, relation)
    validate_columns!(table, relation, columns)
    filters = require_filters!(ast, "UPDATE")

    sets = Enum.map_join(columns, ", ", &"#{quote_ident(&1)} = json_extract(?, #{json_path(&1)})")
    set_params = List.duplicate(payload_json, length(columns))

    {where_sql, params} = build_where(cache, table, relation, filters, [], set_params)
    {"update #{quote_ident(relation)} set #{sets}#{where_sql}" <> returning(opts), params}
  end

  @spec delete(map(), String.t(), String.t(), map()) :: {String.t(), [term()]}
  def delete(cache, schema, relation, ast) do
    table = fetch_table!(cache, schema, relation)
    filters = require_filters!(ast, "DELETE")

    {where_sql, params} = build_where(cache, table, relation, filters, [], [])
    {"delete from #{quote_ident(relation)}#{where_sql}", params}
  end

  defp returning(opts) do
    if Keyword.get(opts, :returning_rowids, false), do: " returning rowid", else: ""
  end

  defp rowid_condition(_relation, []), do: {"1 = 0", []}

  defp rowid_condition(relation, rowids) do
    placeholders = Enum.map_join(rowids, ", ", fn _rowid -> "?" end)
    {"#{quote_ident(relation)}.\"rowid\" in (#{placeholders})", rowids}
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

  defp require_filters!(ast, verb) do
    if Enum.all?(ast.filters, &(&1.path != [])) do
      raise Error.parse_error(
              "#{verb} requires at least one filter to avoid affecting the whole table"
            )
    end

    ast.filters
  end

  defp row_query(cache, table, alias_name, ctx, params, extra_conditions) do
    {json_expr, params} = row_json(cache, table, alias_name, ctx, params)

    {where_sql, params} =
      build_where(cache, table, alias_name, ctx.filters, extra_conditions, params)

    order_sql = build_order(cache, table, alias_name, ctx.order)
    {limit_sql, offset_sql} = limit_offset_sql(ctx)

    sql =
      "select #{json_expr} as js from #{quote_ident(table.name)} as #{quote_ident(alias_name)}" <>
        where_sql <> order_sql <> limit_sql <> offset_sql

    {sql, params}
  end

  defp row_json(cache, table, alias_name, ctx, params) do
    nodes = if ctx.select == [], do: [%{type: :all}], else: ctx.select

    {pairs, params} =
      Enum.flat_map_reduce(nodes, params, fn node, params ->
        case node do
          %{type: :all} ->
            pairs =
              Enum.map(table.column_order, fn column ->
                "#{json_key(column)}, #{column_json(table, alias_name, column, [])}"
              end)

            {pairs, params}

          %{type: :field} = field ->
            fetch_column_type!(table, alias_name, field.name)
            key = field.alias || field.name

            {["#{json_key(key)}, #{column_json(table, alias_name, field.name, field.casts)}"],
             params}

          %{type: :embed} = embed ->
            {expr, params} = embed_json(cache, table, alias_name, embed, ctx, params)
            {["#{json_key(embed.alias || embed.name)}, #{expr}"], params}
        end
      end)

    {"json_object(#{Enum.join(pairs, ", ")})", params}
  end

  defp column_json(table, alias_name, column, casts) do
    qcol = "#{quote_ident(alias_name)}.#{quote_ident(column)}"
    expr = Enum.reduce(casts, qcol, fn cast, acc -> "cast(#{acc} as #{cast})" end)

    if casts == [] and boolean_column?(table, column) do
      "json(iif(#{expr} is null, 'null', iif(#{expr}, 'true', 'false')))"
    else
      expr
    end
  end

  defp boolean_column?(table, column) do
    table.columns |> Map.get(column, "") |> String.downcase() |> String.contains?("bool")
  end

  defp embed_json(cache, table, alias_name, embed, ctx, params) do
    rel = resolve_relationship!(cache, table, embed)

    child_table =
      Map.get(cache.tables, rel.table) ||
        raise Error.undefined_relationship(table.name, embed.name)

    out_name = embed.alias || embed.name
    child_alias = "#{alias_name}_#{out_name}"

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

    case rel.cardinality do
      :m2o ->
        {json_expr, params} = row_json(cache, child_table, child_alias, child_ctx, params)

        {where_sql, params} =
          build_where(cache, child_table, child_alias, child_ctx.filters, join_conditions, params)

        sql =
          "json((select #{json_expr} from #{quote_ident(child_table.name)} as #{quote_ident(child_alias)}" <>
            where_sql <> " limit 1))"

        {sql, params}

      :o2m ->
        {inner, params} =
          row_query(cache, child_table, child_alias, child_ctx, params, join_conditions)

        {"json((select coalesce(json_group_array(json(js)), '[]') from (#{inner}) as _sub))",
         params}
    end
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

  defp condition_sql(_cache, table, alias_name, %{type: :cond} = condition, params) do
    fetch_column_type!(table, alias_name, condition.field)
    qcol = "#{quote_ident(alias_name)}.#{quote_ident(condition.field)}"
    operator_sql(qcol, condition, params)
  end

  defp operator_sql(_qcol, %{op: op}, _params) when op in @unsupported_ops do
    raise Error.parse_error("Operator '#{op}' is not supported by the sqlite adapter")
  end

  defp operator_sql(qcol, %{op: "is"} = condition, params) do
    verb = if condition.negated, do: "is not", else: "is"
    value = if condition.value == "unknown", do: "null", else: condition.value
    {"#{qcol} #{verb} #{value}", params}
  end

  defp operator_sql(qcol, %{op: "in"} = condition, params) do
    placeholders = Enum.map_join(condition.value, ", ", fn _value -> "?" end)
    sql = "#{qcol} in (#{placeholders})"
    {maybe_negate(sql, condition.negated), params ++ condition.value}
  end

  defp operator_sql(qcol, %{op: op} = condition, params) when op in ["like", "ilike"] do
    {maybe_negate("#{qcol} like ?", condition.negated),
     params ++ [String.replace(condition.value, "*", "%")]}
  end

  defp operator_sql(qcol, condition, params) do
    operator = Map.fetch!(@operators, condition.op)
    sql = "#{qcol} #{operator} ?"
    {maybe_negate(sql, condition.negated), params ++ [condition.value]}
  end

  defp maybe_negate(sql, true), do: "not (#{sql})"
  defp maybe_negate(sql, false), do: sql

  defp build_order(_cache, _table, _alias_name, []), do: ""

  defp build_order(_cache, table, alias_name, order_entries) do
    terms = for %{path: [], terms: terms} <- order_entries, term <- terms, do: term

    case terms do
      [] ->
        ""

      terms ->
        Enum.each(terms, &fetch_column_type!(table, alias_name, &1.field))
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

    case {limit, offset} do
      {nil, nil} -> {"", ""}
      {nil, offset} -> {" limit -1", " offset #{offset}"}
      {limit, nil} -> {" limit #{limit}", ""}
      {limit, offset} -> {" limit #{limit}", " offset #{offset}"}
    end
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

  defp validate_columns!(table, relation, columns) do
    Enum.each(columns, &fetch_column_type!(table, relation, &1))

    if columns == [] do
      raise Error.parse_error("Payload has no columns")
    end
  end

  defp fetch_table!(cache, schema, relation) do
    Map.get(cache.tables, {schema, relation}) || raise Error.undefined_relation(relation)
  end

  defp fetch_column_type!(table, relation_label, column) do
    Map.get(table.columns, column) || raise Error.undefined_column(relation_label, column)
  end

  defp json_key(name), do: "'#{escape_literal(name)}'"

  defp json_path(column), do: ~s('$."#{escape_literal(String.replace(column, ~s("), ""))}"')

  defp quote_ident(name) do
    ~s("#{String.replace(name, ~s("), ~s(""))}")
  end

  defp escape_literal(value), do: String.replace(value, "'", "''")
end
