defmodule Postgrext.Adapters.SQLiteTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Postgrext.Adapters.SQLite.Connection

  @fixtures [
    "create table clients (id integer primary key, name text not null)",
    "create table projects (id integer primary key, name text not null, client_id integer references clients(id), budget real)",
    "create table tasks (id integer primary key, name text not null, project_id integer references projects(id), done boolean not null default false)",
    "insert into clients (name) values ('acme'), ('umbrella')",
    "insert into projects (name, client_id, budget) values ('apollo', 1, 100.5), ('gemini', 1, 50), ('skynet', 2, null)",
    "insert into tasks (name, project_id, done) values ('design', 1, 1), ('build', 1, 0), ('launch', 2, 0)"
  ]

  setup do
    previous =
      Enum.map([:adapter, :schemas, :anon_role, :jwt_secret], &{&1, Postgrext.Config.get(&1)})

    Postgrext.Config.put(
      adapter: Postgrext.Adapters.SQLite,
      schemas: ["main"],
      anon_role: nil,
      jwt_secret: nil
    )

    start_supervised!({Connection, database: ":memory:"})
    Enum.each(@fixtures, &Connection.query!(&1, []))

    start_supervised!(
      {Postgrext.SchemaCache, adapter: Postgrext.Adapters.SQLite, schemas: ["main"]}
    )

    on_exit(fn -> Postgrext.Config.put(previous) end)
    :ok
  end

  defp request(method, path, opts \\ []) do
    conn(method, path, opts[:body])
    |> then(fn conn ->
      Enum.reduce(opts[:headers] || [], conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
    end)
    |> Postgrext.Router.call([])
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "reads" do
    test "returns all rows with booleans as json booleans" do
      conn = request(:get, "/tasks?order=id")

      assert conn.status == 200
      assert [%{"name" => "design", "done" => true}, %{"done" => false} | _rest] = json(conn)
    end

    test "selects, aliases, and filters" do
      assert [%{"title" => "apollo"}] =
               request(:get, "/projects?select=title:name&budget=gt.60") |> json()

      assert [%{"name" => "gemini"}] =
               request(:get, "/projects?name=like.gem*&select=name") |> json()

      assert [%{"name" => "skynet"}] =
               request(:get, "/projects?budget=is.null&select=name") |> json()

      assert [%{"name" => "apollo"}, %{"name" => "gemini"}] =
               request(:get, "/projects?id=in.(1,2)&select=name&order=id") |> json()
    end

    test "supports logic trees" do
      conn = request(:get, "/projects?or=(name.eq.apollo,name.eq.skynet)&select=name&order=id")
      assert [%{"name" => "apollo"}, %{"name" => "skynet"}] = json(conn)
    end

    test "orders, limits, and reports ranges with exact counts" do
      conn =
        request(:get, "/projects?select=name&order=id&limit=1&offset=1",
          headers: [{"prefer", "count=exact"}]
        )

      assert json(conn) == [%{"name" => "gemini"}]
      assert get_resp_header(conn, "content-range") == ["1-1/3"]
    end

    test "embeds to-one, to-many, and nested resources" do
      assert [%{"name" => "apollo", "clients" => %{"name" => "acme"}} | _rest] =
               request(:get, "/projects?select=name,clients(name)&order=id") |> json()

      conn =
        request(
          :get,
          "/clients?select=name,projects(name,tasks(name))&projects.order=name.desc&order=id"
        )

      assert [
               %{
                 "name" => "acme",
                 "projects" => [%{"name" => "gemini"} = gemini, %{"name" => "apollo"}]
               },
               %{"name" => "umbrella", "projects" => [%{"name" => "skynet", "tasks" => []}]}
             ] = json(conn)

      assert gemini["tasks"] == [%{"name" => "launch"}]
    end

    test "returns singular objects" do
      conn =
        request(:get, "/projects?id=eq.1&select=name",
          headers: [{"accept", "application/vnd.pgrst.object+json"}]
        )

      assert json(conn) == %{"name" => "apollo"}

      conn =
        request(:get, "/projects", headers: [{"accept", "application/vnd.pgrst.object+json"}])

      assert conn.status == 406
    end

    test "404s unknown relations, 400s unknown columns and unsupported operators" do
      assert request(:get, "/nope").status == 404
      assert request(:get, "/projects?wat=eq.1").status == 400

      conn = request(:get, "/projects?name=fts.cat")
      assert conn.status == 400
      assert json(conn)["message"] =~ "not supported by the sqlite adapter"
    end

    test "root lists relations and no functions" do
      assert %{"relations" => relations, "functions" => []} = request(:get, "/") |> json()
      assert "projects" in relations
    end
  end

  describe "mutations" do
    test "inserts and returns the representation" do
      conn =
        request(:post, "/clients",
          body: Jason.encode!(%{name: "initech"}),
          headers: [{"content-type", "application/json"}, {"prefer", "return=representation"}]
        )

      assert conn.status == 201
      assert [%{"id" => _id, "name" => "initech"}] = json(conn)
    end

    test "bulk inserts with minimal return" do
      conn =
        request(:post, "/clients",
          body: Jason.encode!([%{name: "a"}, %{name: "b"}]),
          headers: [{"content-type", "application/json"}]
        )

      assert conn.status == 201
      assert get_resp_header(conn, "content-range") == ["*/2"]
    end

    test "updates filtered rows and re-reads the representation" do
      conn =
        request(:patch, "/tasks?id=eq.2",
          body: Jason.encode!(%{done: true}),
          headers: [{"content-type", "application/json"}, {"prefer", "return=representation"}]
        )

      assert conn.status == 200
      assert [%{"id" => 2, "done" => true}] = json(conn)
    end

    test "deletes with representation returns the removed rows" do
      conn =
        request(:delete, "/tasks?id=eq.3", headers: [{"prefer", "return=representation"}])

      assert conn.status == 200
      assert [%{"id" => 3, "name" => "launch"}] = json(conn)
      assert request(:get, "/tasks?id=eq.3") |> json() == []
    end

    test "refuses unfiltered updates and deletes" do
      patch_conn =
        request(:patch, "/tasks",
          body: Jason.encode!(%{done: true}),
          headers: [{"content-type", "application/json"}]
        )

      assert patch_conn.status == 400
      assert request(:delete, "/tasks").status == 400
    end

    test "maps constraint violations to 409" do
      conn =
        request(:post, "/tasks",
          body: Jason.encode!(%{name: "orphan", project_id: 9999}),
          headers: [{"content-type", "application/json"}]
        )

      assert conn.status == 409
      assert json(conn)["code"] == "SQLITE_CONSTRAINT_FOREIGNKEY"
    end
  end

  describe "rpc" do
    test "404s since sqlite has no functions" do
      assert request(:get, "/rpc/anything").status == 404
    end
  end
end
