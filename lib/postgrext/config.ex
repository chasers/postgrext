defmodule Postgrext.Config do
  @moduledoc """
  Runtime configuration, sourced from PostgREST-compatible environment
  variables and stored in application env.

  Recognized variables: `PGRST_DB_URI`, `PGRST_DB_SCHEMAS`,
  `PGRST_DB_ANON_ROLE`, `PGRST_DB_POOL`, `PGRST_JWT_SECRET`,
  `PGRST_SERVER_PORT`.

  A `postgres://` URI selects `Postgrext.Adapters.Postgres`; a
  `sqlite:<path>` (or `sqlite::memory:`) URI selects
  `Postgrext.Adapters.SQLite`.
  """

  @spec load(%{optional(String.t()) => String.t()}) :: keyword()
  def load(env \\ System.get_env()) do
    {adapter, db_path} = detect_adapter(env["PGRST_DB_URI"])

    [
      db_uri: env["PGRST_DB_URI"],
      db_path: db_path,
      adapter: adapter,
      schemas: parse_schemas(env["PGRST_DB_SCHEMAS"], adapter.default_schemas()),
      anon_role: env["PGRST_DB_ANON_ROLE"],
      pool_size: parse_int(env["PGRST_DB_POOL"], 10),
      jwt_secret: env["PGRST_JWT_SECRET"],
      port: parse_int(env["PGRST_SERVER_PORT"], 3000)
    ]
  end

  @spec get(atom()) :: term()
  def get(key), do: Application.get_env(:postgrext, key)

  @spec adapter() :: module()
  def adapter, do: get(:adapter) || Postgrext.Adapters.Postgres

  defp detect_adapter("sqlite:" <> path) do
    {Postgrext.Adapters.SQLite, String.replace_prefix(path, "//", "")}
  end

  defp detect_adapter(_uri), do: {Postgrext.Adapters.Postgres, nil}

  @spec put(keyword()) :: :ok
  def put(config) do
    Enum.each(config, fn {key, value} -> Application.put_env(:postgrext, key, value) end)
  end

  @spec default_schema() :: String.t()
  def default_schema, do: hd(get(:schemas) || ["public"])

  @spec db_opts(String.t()) :: keyword()
  def db_opts(uri) do
    parsed = URI.parse(uri)
    [userinfo_user, userinfo_pass] = split_userinfo(parsed.userinfo)

    [
      hostname: parsed.host || "localhost",
      port: parsed.port || 5432,
      database: String.trim_leading(parsed.path || "/postgres", "/"),
      username: userinfo_user || System.get_env("USER"),
      password: userinfo_pass
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(ssl_opts(parsed.query))
  end

  defp split_userinfo(nil), do: [nil, nil]

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user] -> [URI.decode(user), nil]
      [user, pass] -> [URI.decode(user), URI.decode(pass)]
    end
  end

  defp ssl_opts(nil), do: []

  defp ssl_opts(query) do
    case URI.decode_query(query) do
      %{"sslmode" => mode} when mode in ["require", "verify-ca", "verify-full"] -> [ssl: true]
      %{"ssl" => "true"} -> [ssl: true]
      _other -> []
    end
  end

  defp parse_schemas(nil, default), do: default

  defp parse_schemas(value, default) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      schemas -> schemas
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _other -> default
    end
  end
end
