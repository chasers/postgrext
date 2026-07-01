defmodule Postgrext.SchemaCache.Introspection do
  @moduledoc """
  Queries pg_catalog to build the schema cache: relations, columns, primary
  keys, foreign-key relationships (both directions), and callable functions
  for the exposed schemas.
  """

  @relations_sql """
  select n.nspname, c.relname, c.relkind::text
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = any($1) and c.relkind = any('{r,v,m,p,f}')
  """

  @columns_sql """
  select n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = any($1)
    and c.relkind = any('{r,v,m,p,f}')
    and a.attnum > 0
    and not a.attisdropped
  order by a.attnum
  """

  @primary_keys_sql """
  select n.nspname, c.relname, a.attname
  from pg_index i
  join pg_class c on c.oid = i.indrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum = any(i.indkey)
  where i.indisprimary and n.nspname = any($1)
  """

  @foreign_keys_sql """
  select con.conname,
         fn.nspname, fc.relname,
         (select array_agg(a.attname order by k.ord)
            from unnest(con.conkey) with ordinality k(attnum, ord)
            join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum),
         tn.nspname, tc.relname,
         (select array_agg(a.attname order by k.ord)
            from unnest(con.confkey) with ordinality k(attnum, ord)
            join pg_attribute a on a.attrelid = con.confrelid and a.attnum = k.attnum)
  from pg_constraint con
  join pg_class fc on fc.oid = con.conrelid
  join pg_namespace fn on fn.oid = fc.relnamespace
  join pg_class tc on tc.oid = con.confrelid
  join pg_namespace tn on tn.oid = tc.relnamespace
  where con.contype = 'f' and (fn.nspname = any($1) or tn.nspname = any($1))
  """

  @functions_sql """
  select n.nspname, p.proname, p.proretset,
         coalesce(p.proargnames, '{}'::text[]),
         coalesce((select array_agg(format_type(t.oid, null) order by t.ord)
            from unnest(p.proargtypes) with ordinality t(oid, ord)), '{}'::text[]),
         format_type(p.prorettype, null),
         exists(select 1 from pg_type ty
                where ty.oid = p.prorettype and ty.typtype in ('c', 'p')),
         coalesce(rn.nspname, ''), coalesce(rc.relname, '')
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  left join pg_class rc on rc.reltype = p.prorettype
  left join pg_namespace rn on rn.oid = rc.relnamespace
  where n.nspname = any($1) and p.prokind = 'f'
  """

  @spec load(pid() | atom(), [String.t()]) :: map()
  def load(conn, schemas) do
    %{
      tables: load_tables(conn, schemas),
      relationships: load_relationships(conn, schemas),
      functions: load_functions(conn, schemas)
    }
  end

  defp load_tables(conn, schemas) do
    relations = query_rows(conn, @relations_sql, [schemas])
    columns = query_rows(conn, @columns_sql, [schemas])
    pks = query_rows(conn, @primary_keys_sql, [schemas])

    columns_by_table =
      Enum.group_by(columns, fn [s, t, _c, _ty] -> {s, t} end, fn [_s, _t, c, ty] ->
        {c, ty}
      end)

    pks_by_table =
      Enum.group_by(pks, fn [s, t, _c] -> {s, t} end, fn [_s, _t, c] -> c end)

    Map.new(relations, fn [schema, name, kind] ->
      cols = Map.get(columns_by_table, {schema, name}, [])

      {{schema, name},
       %{
         schema: schema,
         name: name,
         kind: kind,
         columns: Map.new(cols),
         column_order: Enum.map(cols, &elem(&1, 0)),
         pk: Map.get(pks_by_table, {schema, name}, [])
       }}
    end)
  end

  defp load_relationships(conn, schemas) do
    conn
    |> query_rows(@foreign_keys_sql, [schemas])
    |> Enum.flat_map(fn [conname, fs, ft, fcols, ts, tt, tcols] ->
      m2o = %{
        cardinality: :m2o,
        constraint: conname,
        table: {ts, tt},
        cols: fcols,
        foreign_cols: tcols
      }

      o2m = %{
        cardinality: :o2m,
        constraint: conname,
        table: {fs, ft},
        cols: tcols,
        foreign_cols: fcols
      }

      [{{fs, ft}, m2o}, {{ts, tt}, o2m}]
    end)
    |> Enum.group_by(fn {key, _rel} -> key end, fn {_key, rel} -> rel end)
  end

  defp load_functions(conn, schemas) do
    conn
    |> query_rows(@functions_sql, [schemas])
    |> Map.new(fn [schema, name, retset, argnames, argtypes, rettype, composite, rs, rt] ->
      {{schema, name},
       %{
         schema: schema,
         name: name,
         retset: retset,
         args: Enum.zip(argnames, argtypes),
         rettype: rettype,
         returns_rows: retset or composite,
         rettype_relation: if(rs != "" and rt != "", do: {rs, rt})
       }}
    end)
  end

  defp query_rows(conn, sql, params) do
    Postgrex.query!(conn, sql, params).rows
  end
end
