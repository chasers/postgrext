defmodule Postgrext.Query.BuilderTest do
  use ExUnit.Case, async: true

  alias Postgrext.Query.Builder
  alias Postgrext.Request.Parser

  defp cache do
    %{
      tables: %{
        {"public", "projects"} => %{
          schema: "public",
          name: "projects",
          kind: "r",
          columns: %{
            "id" => "integer",
            "name" => "text",
            "client_id" => "integer",
            "budget" => "numeric"
          },
          column_order: ["id", "name", "client_id", "budget"],
          pk: ["id"]
        },
        {"public", "clients"} => %{
          schema: "public",
          name: "clients",
          kind: "r",
          columns: %{"id" => "integer", "name" => "text"},
          column_order: ["id", "name"],
          pk: ["id"]
        },
        {"public", "tasks"} => %{
          schema: "public",
          name: "tasks",
          kind: "r",
          columns: %{"id" => "integer", "name" => "text", "project_id" => "integer"},
          column_order: ["id", "name", "project_id"],
          pk: ["id"]
        }
      },
      relationships: %{
        {"public", "projects"} => [
          %{
            cardinality: :m2o,
            constraint: "projects_client_id_fkey",
            table: {"public", "clients"},
            cols: ["client_id"],
            foreign_cols: ["id"]
          },
          %{
            cardinality: :o2m,
            constraint: "tasks_project_id_fkey",
            table: {"public", "tasks"},
            cols: ["id"],
            foreign_cols: ["project_id"]
          }
        ],
        {"public", "clients"} => [
          %{
            cardinality: :o2m,
            constraint: "projects_client_id_fkey",
            table: {"public", "projects"},
            cols: ["id"],
            foreign_cols: ["client_id"]
          }
        ]
      },
      functions: %{
        {"public", "add_them"} => %{
          schema: "public",
          name: "add_them",
          retset: false,
          args: [{"a", "integer"}, {"b", "integer"}],
          rettype: "integer",
          returns_rows: false,
          rettype_relation: nil
        },
        {"public", "get_projects"} => %{
          schema: "public",
          name: "get_projects",
          retset: true,
          args: [],
          rettype: "projects",
          returns_rows: true,
          rettype_relation: {"public", "projects"}
        },
        {"public", "do_nothing"} => %{
          schema: "public",
          name: "do_nothing",
          retset: false,
          args: [],
          rettype: "void",
          returns_rows: false,
          rettype_relation: nil
        }
      }
    }
  end

  defp read(query_string, opts \\ []) do
    Builder.read(cache(), "public", "projects", Parser.parse(query_string), opts)
  end

  describe "read" do
    test "selects all columns by default" do
      {sql, params} = read("")

      assert sql =~ ~s|select "projects".* from "public"."projects" as "projects"|
      assert sql =~ "coalesce(json_agg(_body), '[]')::text"
      assert params == []
    end

    test "selects specific columns with alias and cast" do
      {sql, _params} = read("select=id,label:name,budget::text")

      assert sql =~ ~s|"projects"."id"|
      assert sql =~ ~s|"projects"."name" as "label"|
      assert sql =~ ~s|"projects"."budget"::text as "budget"|
    end

    test "builds typed filter casts" do
      {sql, params} = read("id=eq.5&name=like.a*")

      assert sql =~ ~s|"projects"."id" = (($1::text)::integer)|
      assert sql =~ ~s|"projects"."name" like ($2::text)|
      assert params == ["5", "a%"]
    end

    test "builds in filters as arrays" do
      {sql, params} = read("id=in.(1,2,3)")

      assert sql =~ ~s|"projects"."id" = any(($1::text[])::integer[])|
      assert params == [["1", "2", "3"]]
    end

    test "builds is and negation" do
      {sql, _params} = read("client_id=is.null&name=not.eq.bob")

      assert sql =~ ~s|"projects"."client_id" is null|
      assert sql =~ ~s|not ("projects"."name" =|
    end

    test "builds logic trees" do
      {sql, params} = read("or=(id.eq.1,and(id.gte.2,id.lte.4))")

      assert sql =~
               ~s{("projects"."id" = (($1::text)::integer) or ("projects"."id" >= (($2::text)::integer) and "projects"."id" <= (($3::text)::integer)))}

      assert params == ["1", "2", "4"]
    end

    test "builds order, limit, offset" do
      {sql, _params} = read("order=name.desc.nullslast,id&limit=5&offset=10")

      assert sql =~ ~s|order by "projects"."name" desc nulls last, "projects"."id"|
      assert sql =~ "limit 5"
      assert sql =~ "offset 10"
    end

    test "builds singular body" do
      {sql, _params} = read("", singular: true)
      assert sql =~ "coalesce(json_agg(_body) -> 0, 'null')::text"
    end

    test "embeds a to-one relationship via lateral to_json" do
      {sql, _params} = read("select=name,clients(name)")

      assert sql =~ "left join lateral (select to_json(_sub) as _json"
      assert sql =~ ~s|"projects_clients"."id" = "projects"."client_id"|
      assert sql =~ ~s|"projects_clients_j"._json as "clients"|
    end

    test "embeds a to-many relationship via json_agg" do
      {sql, _params} = read("select=name,tasks(name)")

      assert sql =~ "coalesce(json_agg(_sub), '[]') as _json"
      assert sql =~ ~s|"projects_tasks"."project_id" = "projects"."id"|
    end

    test "applies scoped filters, order, and limit inside the embed" do
      {sql, params} = read("select=name,tasks(name)&tasks.name=eq.review&tasks.limit=2")

      assert sql =~ ~s|"projects_tasks"."name" = (($1::text)::text)|
      assert sql =~ "limit 2"
      assert params == ["review"]
    end

    test "supports nested embeds" do
      {sql, _params} =
        Builder.read(
          cache(),
          "public",
          "clients",
          Parser.parse("select=name,projects(name,tasks(name))"),
          []
        )

      assert sql =~ ~s|"clients_projects"."client_id" = "clients"."id"|
      assert sql =~ ~s|"clients_projects_tasks"."project_id" = "clients_projects"."id"|
    end

    test "raises on unknown relation" do
      assert_raise Postgrext.Error, ~r/table 'nope'/, fn ->
        Builder.read(cache(), "public", "nope", Parser.parse(""), [])
      end
    end

    test "raises on unknown column" do
      assert_raise Postgrext.Error, ~r/'wat' column/, fn ->
        read("wat=eq.1")
      end
    end

    test "raises on unknown relationship" do
      assert_raise Postgrext.Error, ~r/relationship between 'projects' and 'tasks2'/, fn ->
        read("select=tasks2(name)")
      end
    end
  end

  describe "count" do
    test "counts with base filters only" do
      {sql, params} = Builder.count(cache(), "public", "projects", Parser.parse("id=gt.5"))

      assert sql =~ ~s|select count(*)::bigint from "public"."projects" as "projects"|
      assert sql =~ ~s|"projects"."id" > (($1::text)::integer)|
      assert params == ["5"]
    end
  end

  describe "mutations" do
    test "insert minimal" do
      {sql, params} =
        Builder.insert(
          cache(),
          "public",
          "projects",
          Parser.parse(""),
          ~s|[{"name":"n"}]|,
          ["name"],
          returning: :minimal
        )

      assert sql =~ ~s{insert into "public"."projects" ("name")}
      assert sql =~ "json_populate_recordset(null::\"public\".\"projects\", ($1::text)::json)"
      refute sql =~ "returning"
      assert params == [~s|[{"name":"n"}]|]
    end

    test "insert with representation applies the select tree" do
      {sql, _params} =
        Builder.insert(
          cache(),
          "public",
          "projects",
          Parser.parse("select=id,clients(name)"),
          "[]",
          ["name"],
          returning: :representation
        )

      assert sql =~ "with _mutated as (insert into"
      assert sql =~ "returning *"
      assert sql =~ ~s|from _mutated as "projects"|
      assert sql =~ "left join lateral"
    end

    test "update requires filters" do
      assert_raise Postgrext.Error, ~r/UPDATE requires at least one filter/, fn ->
        Builder.update(cache(), "public", "projects", Parser.parse(""), "{}", ["name"],
          returning: :minimal
        )
      end
    end

    test "update builds a multi-column set from the payload" do
      {sql, params} =
        Builder.update(
          cache(),
          "public",
          "projects",
          Parser.parse("id=eq.1"),
          ~s|{"name":"x"}|,
          ["name"],
          returning: :minimal
        )

      assert sql =~ ~s{update "public"."projects" as "projects" set ("name") =}
      assert sql =~ "json_populate_record(null::\"public\".\"projects\", ($1::text)::json)"
      assert sql =~ ~s|"projects"."id" = (($2::text)::integer)|
      assert params == [~s|{"name":"x"}|, "1"]
    end

    test "delete requires filters" do
      assert_raise Postgrext.Error, ~r/DELETE requires at least one filter/, fn ->
        Builder.delete(cache(), "public", "projects", Parser.parse(""), returning: :minimal)
      end
    end

    test "delete with representation" do
      {sql, params} =
        Builder.delete(cache(), "public", "projects", Parser.parse("id=eq.9"),
          returning: :representation
        )

      assert sql =~ ~s{delete from "public"."projects" as "projects" where}
      assert sql =~ "returning *"
      assert params == ["9"]
    end
  end

  describe "rpc" do
    test "scalar function" do
      {sql, params, :scalar} =
        Builder.rpc(cache(), "public", "add_them", Parser.parse(""), %{"a" => "1", "b" => 2})

      assert sql =~ ~s{"public"."add_them"("a" := ($1::text)::integer, "b" := ($2::text)::integer}
      assert sql =~ "to_json"
      assert Enum.sort(params) == ["1", "2"]
    end

    test "void function" do
      {sql, [], :void} = Builder.rpc(cache(), "public", "do_nothing", Parser.parse(""), %{})
      assert sql == ~s{select "public"."do_nothing"()}
    end

    test "setof function with a known return relation supports filters" do
      {sql, params, :rows} =
        Builder.rpc(cache(), "public", "get_projects", Parser.parse("id=gt.1&select=name"), %{})

      assert sql =~ ~s{from "public"."get_projects"() as "get_projects"}
      assert sql =~ ~s{"get_projects"."id" > (($1::text)::integer)}
      assert params == ["1"]
    end

    test "unknown argument raises" do
      assert_raise Postgrext.Error, ~r/Unknown argument 'c'/, fn ->
        Builder.rpc(cache(), "public", "add_them", Parser.parse(""), %{"c" => "1"})
      end
    end

    test "unknown function raises" do
      assert_raise Postgrext.Error, ~r/function 'nope'/, fn ->
        Builder.rpc(cache(), "public", "nope", Parser.parse(""), %{})
      end
    end
  end
end
