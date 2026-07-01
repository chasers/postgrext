defmodule Postgrext.ConfigTest do
  use ExUnit.Case, async: true

  alias Postgrext.Config

  test "defaults" do
    config = Config.load(%{})

    assert config[:db_uri] == nil
    assert config[:schemas] == ["public"]
    assert config[:anon_role] == nil
    assert config[:pool_size] == 10
    assert config[:port] == 3000
  end

  test "reads PostgREST-style variables" do
    config =
      Config.load(%{
        "PGRST_DB_URI" => "postgres://u:p@db:5433/app",
        "PGRST_DB_SCHEMAS" => "api, private",
        "PGRST_DB_ANON_ROLE" => "web_anon",
        "PGRST_DB_POOL" => "5",
        "PGRST_JWT_SECRET" => "secret",
        "PGRST_SERVER_PORT" => "4001"
      })

    assert config[:db_uri] == "postgres://u:p@db:5433/app"
    assert config[:schemas] == ["api", "private"]
    assert config[:anon_role] == "web_anon"
    assert config[:pool_size] == 5
    assert config[:jwt_secret] == "secret"
    assert config[:port] == 4001
  end

  test "falls back on unparsable numbers" do
    config = Config.load(%{"PGRST_DB_POOL" => "many", "PGRST_SERVER_PORT" => "-1"})
    assert config[:pool_size] == 10
    assert config[:port] == 3000
  end

  test "db_opts parses a connection uri" do
    opts = Config.db_opts("postgres://user:pa%40ss@db.example.com:5433/mydb")

    assert opts[:hostname] == "db.example.com"
    assert opts[:port] == 5433
    assert opts[:database] == "mydb"
    assert opts[:username] == "user"
    assert opts[:password] == "pa@ss"
    refute opts[:ssl]
  end

  test "db_opts handles sslmode and missing parts" do
    opts = Config.db_opts("postgres://db/app?sslmode=require")

    assert opts[:hostname] == "db"
    assert opts[:port] == 5432
    assert opts[:database] == "app"
    assert opts[:ssl] == true
  end
end
