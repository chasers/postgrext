defmodule Postgrext.IntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  @schema "postgrext_test"

  @fixtures """
  create schema #{@schema};
  set local search_path to #{@schema};

  create table clients (
    id serial primary key,
    name text not null
  );

  create table projects (
    id serial primary key,
    name text not null,
    client_id int references clients(id),
    budget numeric
  );

  create table tasks (
    id serial primary key,
    name text not null,
    project_id int references projects(id),
    done boolean not null default false
  );

  insert into clients (name) values ('acme'), ('umbrella');
  insert into projects (name, client_id, budget) values
    ('apollo', 1, 100.5),
    ('gemini', 1, 50),
    ('skynet', 2, null);
  insert into tasks (name, project_id, done) values
    ('design', 1, true),
    ('build', 1, false),
    ('launch', 2, false);

  create function add_them(a int, b int) returns int
    language sql immutable as 'select a + b';

  create function get_projects() returns setof projects
    language sql stable as 'select * from #{@schema}.projects';

  create function ping() returns void
    language sql as '';
  """

  setup_all do
    unless Process.whereis(Postgrext.DB) do
      opts =
        Postgrext.Config.db_opts(
          System.get_env("PGRST_DB_URI", "postgres://localhost:5432/postgres")
        )

      {:ok, _pid} = Postgrex.start_link([name: Postgrext.DB, pool_size: 3] ++ opts)
    end

    previous_schemas = Postgrext.Config.get(:schemas)
    previous_adapter = Postgrext.Config.get(:adapter)

    Postgrext.Config.put(
      adapter: Postgrext.Adapters.Postgres,
      schemas: [@schema],
      anon_role: nil,
      jwt_secret: nil
    )

    Postgrex.query!(Postgrext.DB, "drop schema if exists #{@schema} cascade", [])

    statements =
      @fixtures
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, _result} =
      Postgrex.transaction(Postgrext.DB, fn conn ->
        Enum.each(statements, &Postgrex.query!(conn, &1, []))
      end)

    start_supervised!(
      {Postgrext.SchemaCache, adapter: Postgrext.Adapters.Postgres, schemas: [@schema]}
    )

    on_exit(fn ->
      Postgrex.query!(Postgrext.DB, "drop schema if exists #{@schema} cascade", [])
      Postgrext.Config.put(schemas: previous_schemas, adapter: previous_adapter)
    end)

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

  describe "GET" do
    test "returns all rows" do
      conn = request(:get, "/projects")

      assert conn.status == 200
      assert length(json(conn)) == 3
      assert [%{"id" => _, "name" => _, "client_id" => _, "budget" => _} | _rest] = json(conn)
    end

    test "selects, aliases, and casts columns" do
      conn = request(:get, "/projects?select=title:name,budget::text&order=id")

      assert [%{"title" => "apollo", "budget" => "100.5"} | _rest] = json(conn)
    end

    test "filters with comparison operators" do
      conn = request(:get, "/projects?budget=gt.60&select=name")
      assert json(conn) == [%{"name" => "apollo"}]
    end

    test "filters with in, like, and is" do
      assert [%{"name" => "apollo"}, %{"name" => "gemini"}] =
               request(:get, "/projects?id=in.(1,2)&select=name&order=id") |> json()

      assert [%{"name" => "gemini"}] =
               request(:get, "/projects?name=like.gem*&select=name") |> json()

      assert [%{"name" => "skynet"}] =
               request(:get, "/projects?budget=is.null&select=name") |> json()
    end

    test "filters with or logic" do
      conn = request(:get, "/projects?or=(name.eq.apollo,name.eq.skynet)&select=name&order=id")
      assert [%{"name" => "apollo"}, %{"name" => "skynet"}] = json(conn)
    end

    test "orders, limits, offsets, and reports the content range" do
      conn = request(:get, "/projects?select=name&order=id&limit=1&offset=1")

      assert json(conn) == [%{"name" => "gemini"}]
      assert get_resp_header(conn, "content-range") == ["1-1/*"]
    end

    test "returns the exact count when preferred" do
      conn =
        request(:get, "/projects?select=name&limit=2&order=id",
          headers: [{"prefer", "count=exact"}]
        )

      assert get_resp_header(conn, "content-range") == ["0-1/3"]
    end

    test "embeds a to-one relationship" do
      conn = request(:get, "/projects?select=name,clients(name)&order=id")

      assert [
               %{"name" => "apollo", "clients" => %{"name" => "acme"}},
               %{"name" => "gemini", "clients" => %{"name" => "acme"}},
               %{"name" => "skynet", "clients" => %{"name" => "umbrella"}}
             ] = json(conn)
    end

    test "embeds a to-many relationship with scoped filters and order" do
      conn =
        request(
          :get,
          "/clients?select=name,projects(name,tasks(name))&projects.order=name.desc&order=id"
        )

      assert [
               %{"name" => "acme", "projects" => [gemini, apollo]},
               %{"name" => "umbrella", "projects" => [%{"name" => "skynet", "tasks" => []}]}
             ] = json(conn)

      assert %{"name" => "gemini", "tasks" => [%{"name" => "launch"}]} = gemini
      assert %{"name" => "apollo", "tasks" => [_design, _build]} = apollo
    end

    test "returns a single object for the singular media type" do
      conn =
        request(:get, "/projects?id=eq.1&select=name",
          headers: [{"accept", "application/vnd.pgrst.object+json"}]
        )

      assert conn.status == 200
      assert json(conn) == %{"name" => "apollo"}
    end

    test "rejects singular responses with multiple rows" do
      conn =
        request(:get, "/projects", headers: [{"accept", "application/vnd.pgrst.object+json"}])

      assert conn.status == 406
      assert %{"code" => "PGRST116"} = json(conn)
    end

    test "404s on unknown relations and 400s on unknown columns" do
      assert request(:get, "/nope").status == 404
      assert %{"code" => "PGRST205"} = request(:get, "/nope") |> json()

      conn = request(:get, "/projects?wat=eq.1")
      assert conn.status == 400
      assert %{"code" => "PGRST204"} = json(conn)
    end

    test "root lists relations and functions" do
      conn = request(:get, "/")

      assert %{"relations" => relations, "functions" => functions} = json(conn)
      assert "projects" in relations
      assert "add_them" in functions
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
      assert [%{"id" => id, "name" => "initech"}] = json(conn)

      on_exit(fn ->
        Postgrex.query!(Postgrext.DB, "delete from #{@schema}.clients where id = $1", [id])
      end)
    end

    test "bulk inserts with minimal return" do
      conn =
        request(:post, "/clients",
          body: Jason.encode!([%{name: "bulk_a"}, %{name: "bulk_b"}]),
          headers: [{"content-type", "application/json"}]
        )

      assert conn.status == 201
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-range") == ["*/2"]

      on_exit(fn ->
        Postgrex.query!(
          Postgrext.DB,
          "delete from #{@schema}.clients where name like 'bulk_%'",
          []
        )
      end)
    end

    test "rejects inserts with mismatched keys" do
      conn =
        request(:post, "/clients",
          body: Jason.encode!([%{name: "x"}, %{nome: "y"}]),
          headers: [{"content-type", "application/json"}]
        )

      assert conn.status == 400
      assert json(conn)["message"] == "All object keys must match"
    end

    test "updates filtered rows and returns the representation" do
      %{rows: [[id]]} =
        Postgrex.query!(
          Postgrext.DB,
          "insert into #{@schema}.tasks (name, project_id) values ('temp', 1) returning id",
          []
        )

      on_exit(fn ->
        Postgrex.query!(Postgrext.DB, "delete from #{@schema}.tasks where id = $1", [id])
      end)

      conn =
        request(:patch, "/tasks?id=eq.#{id}",
          body: Jason.encode!(%{done: true}),
          headers: [{"content-type", "application/json"}, {"prefer", "return=representation"}]
        )

      assert conn.status == 200
      assert [%{"id" => ^id, "done" => true}] = json(conn)
    end

    test "refuses updates and deletes without filters" do
      patch_conn =
        request(:patch, "/tasks",
          body: Jason.encode!(%{done: true}),
          headers: [{"content-type", "application/json"}]
        )

      assert patch_conn.status == 400
      assert request(:delete, "/tasks").status == 400
    end

    test "deletes filtered rows" do
      %{rows: [[id]]} =
        Postgrex.query!(
          Postgrext.DB,
          "insert into #{@schema}.tasks (name, project_id) values ('doomed', 1) returning id",
          []
        )

      conn = request(:delete, "/tasks?id=eq.#{id}")

      assert conn.status == 204
      assert get_resp_header(conn, "content-range") == ["*/1"]

      %{rows: [[count]]} =
        Postgrex.query!(Postgrext.DB, "select count(*) from #{@schema}.tasks where id = $1", [id])

      assert count == 0
    end

    test "maps foreign key violations to 409" do
      conn =
        request(:post, "/tasks",
          body: Jason.encode!(%{name: "orphan", project_id: 9999}),
          headers: [{"content-type", "application/json"}]
        )

      assert conn.status == 409
      assert %{"code" => "23503"} = json(conn)
    end
  end

  describe "rpc" do
    test "calls a scalar function with GET args" do
      conn = request(:get, "/rpc/add_them?a=20&b=22")

      assert conn.status == 200
      assert json(conn) == 42
    end

    test "calls a scalar function with a POST body" do
      conn =
        request(:post, "/rpc/add_them",
          body: Jason.encode!(%{a: 1, b: 2}),
          headers: [{"content-type", "application/json"}]
        )

      assert json(conn) == 3
    end

    test "calls a set-returning function with filters" do
      conn = request(:get, "/rpc/get_projects?budget=gt.60&select=name")

      assert json(conn) == [%{"name" => "apollo"}]
    end

    test "calls a void function" do
      conn = request(:post, "/rpc/ping")
      assert conn.status == 204
    end

    test "404s on unknown functions" do
      assert request(:get, "/rpc/nope").status == 404
    end
  end
end
