defmodule Postgrext.Adapters.SQLite.BuilderTest do
  use ExUnit.Case, async: true

  alias Postgrext.Adapters.SQLite.Builder
  alias Postgrext.Request.Parser

  defp cache do
    %{
      tables: %{
        {"main", "projects"} => %{
          schema: "main",
          name: "projects",
          kind: "r",
          columns: %{
            "id" => "INTEGER",
            "name" => "TEXT",
            "client_id" => "INTEGER",
            "done" => "BOOLEAN"
          },
          column_order: ["id", "name", "client_id", "done"],
          pk: ["id"]
        },
        {"main", "clients"} => %{
          schema: "main",
          name: "clients",
          kind: "r",
          columns: %{"id" => "INTEGER", "name" => "TEXT"},
          column_order: ["id", "name"],
          pk: ["id"]
        }
      },
      relationships: %{
        {"main", "projects"} => [
          %{
            cardinality: :m2o,
            constraint: "projects_client_id_fkey",
            table: {"main", "clients"},
            cols: ["client_id"],
            foreign_cols: ["id"]
          }
        ],
        {"main", "clients"} => [
          %{
            cardinality: :o2m,
            constraint: "projects_client_id_fkey",
            table: {"main", "projects"},
            cols: ["id"],
            foreign_cols: ["client_id"]
          }
        ]
      },
      functions: %{}
    }
  end

  defp read(query_string, opts \\ []) do
    Builder.read(cache(), "main", "projects", Parser.parse(query_string), opts)
  end

  test "expands star to json_object over cached columns" do
    {sql, params} = read("")

    assert sql =~ "json_group_array(json(js))"
    assert sql =~ ~s|'id', "projects"."id"|
    assert sql =~ ~s|'name', "projects"."name"|
    assert params == []
  end

  test "renders boolean columns as json true/false" do
    {sql, _params} = read("select=done")

    assert sql =~
             ~s|json(iif("projects"."done" is null, 'null', iif("projects"."done", 'true', 'false')))|
  end

  test "builds positional placeholders without casts" do
    {sql, params} = read("id=eq.5&name=like.a*")

    assert sql =~ ~s|"projects"."id" = ?|
    assert sql =~ ~s|"projects"."name" like ?|
    assert params == ["5", "a%"]
  end

  test "expands in filters to placeholder lists" do
    {sql, params} = read("id=in.(1,2,3)")

    assert sql =~ ~s|"projects"."id" in (?, ?, ?)|
    assert params == ["1", "2", "3"]
  end

  test "embeds to-one as a correlated subquery" do
    {sql, _params} = read("select=name,clients(name)")

    assert sql =~ "json((select json_object('name', \"projects_clients\".\"name\")"
    assert sql =~ ~s|"projects_clients"."id" = "projects"."client_id"|
    assert sql =~ "limit 1))"
  end

  test "embeds to-many as json_group_array" do
    {sql, _params} =
      Builder.read(cache(), "main", "clients", Parser.parse("select=name,projects(name)"), [])

    assert sql =~ "coalesce(json_group_array(json(js)), '[]')"
    assert sql =~ ~s|"clients_projects"."client_id" = "clients"."id"|
  end

  test "builds singular bodies via json_extract" do
    {sql, _params} = read("", singular: true)
    assert sql =~ "json_extract(json_group_array(json(js)), '$[0]')"
  end

  test "restricts reads to rowids" do
    {sql, params} = read("select=name", rowids: [7, 9])

    assert sql =~ ~s|"projects"."rowid" in (?, ?)|
    assert params == [7, 9]
  end

  test "rejects operators without sqlite equivalents" do
    assert_raise Postgrext.Error, ~r/not supported by the sqlite adapter/, fn ->
      read("name=fts.cat")
    end
  end

  test "insert extracts payload columns via json_each" do
    {sql, []} = Builder.insert(cache(), "main", "projects", ["name"], returning_rowids: true)

    assert sql =~ ~s{insert into "projects" ("name")}
    assert sql =~ ~s|select json_extract(value, '$."name"') from json_each(?)|
    assert sql =~ "returning rowid"
  end

  test "update sets columns from the payload and requires filters" do
    {sql, params} =
      Builder.update(cache(), "main", "projects", Parser.parse("id=eq.1"), "{}", ["name"],
        returning_rowids: false
      )

    assert sql =~ ~s|set "name" = json_extract(?, '$."name"')|
    assert sql =~ ~s|"projects"."id" = ?|
    assert params == ["{}", "1"]

    assert_raise Postgrext.Error, ~r/UPDATE requires at least one filter/, fn ->
      Builder.update(cache(), "main", "projects", Parser.parse(""), "{}", ["name"], [])
    end
  end

  test "delete requires filters" do
    {sql, params} = Builder.delete(cache(), "main", "projects", Parser.parse("id=eq.9"))
    assert sql =~ ~s|delete from "projects" where|
    assert params == ["9"]

    assert_raise Postgrext.Error, ~r/DELETE requires at least one filter/, fn ->
      Builder.delete(cache(), "main", "projects", Parser.parse(""))
    end
  end

  test "raises on unknown relations and columns" do
    assert_raise Postgrext.Error, ~r/table 'nope'/, fn ->
      Builder.read(cache(), "main", "nope", Parser.parse(""), [])
    end

    assert_raise Postgrext.Error, ~r/'wat' column/, fn ->
      read("wat=eq.1")
    end
  end
end
