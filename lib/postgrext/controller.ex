defmodule Postgrext.Controller do
  @moduledoc """
  Translates HTTP requests into adapter operations: resolves auth, parses the
  query string and payload, dispatches to the configured
  `Postgrext.Adapter`, and renders PostgREST-style responses (JSON bodies,
  `Content-Range`, `Prefer` handling).
  """

  import Plug.Conn

  alias Postgrext.Auth
  alias Postgrext.Error
  alias Postgrext.Request.Parser
  alias Postgrext.SchemaCache

  @object_media_type "application/vnd.pgrst.object+json"

  @spec read(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def read(conn, relation) do
    safely(conn, fn ->
      req = request_context(conn)
      ast = Parser.parse(conn.query_string)

      result =
        Postgrext.Config.adapter().read(SchemaCache.get(), req.schema, relation, ast,
          singular: req.singular,
          total: req.prefer.count,
          auth: req.auth
        )

      check_singular!(req, result.count)

      conn
      |> put_json_content_type(req)
      |> put_content_range(offset_of(ast), result.count, result.total)
      |> send_resp(200, result.body)
    end)
  end

  @spec create(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create(conn, relation) do
    mutate(conn, 201, fn req, ast, payload, opts ->
      rows = List.wrap(payload)
      columns = uniform_columns!(rows)

      Postgrext.Config.adapter().insert(
        SchemaCache.get(),
        req.schema,
        relation,
        ast,
        rows,
        columns,
        opts
      )
    end)
  end

  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, relation) do
    mutate(conn, 200, fn req, ast, payload, opts ->
      unless is_map(payload) do
        raise Error.parse_error("PATCH requires a JSON object body")
      end

      Postgrext.Config.adapter().update(
        SchemaCache.get(),
        req.schema,
        relation,
        ast,
        payload,
        Map.keys(payload),
        opts
      )
    end)
  end

  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, relation) do
    safely(conn, fn ->
      req = request_context(conn)
      ast = Parser.parse(conn.query_string)
      returning = req.prefer.return || :minimal

      result =
        Postgrext.Config.adapter().delete(SchemaCache.get(), req.schema, relation, ast,
          returning: returning,
          singular: req.singular,
          auth: req.auth
        )

      respond_mutation(conn, req, 200, returning, result)
    end)
  end

  @spec rpc(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def rpc(conn, fname) do
    safely(conn, fn ->
      req = request_context(conn)
      cache = SchemaCache.get()

      fn_info =
        Map.get(cache.functions, {req.schema, fname}) || raise Error.undefined_function(fname)

      arg_names = MapSet.new(Enum.map(fn_info.args, &elem(&1, 0)))
      {args, conn} = rpc_args(conn, arg_names)
      ast = Parser.parse(conn.query_string, skip_keys: MapSet.new(Map.keys(args)))

      case Postgrext.Config.adapter().rpc(cache, req.schema, fname, ast, args,
             singular: req.singular,
             auth: req.auth
           ) do
        :void ->
          send_resp(conn, 204, "")

        {:scalar, body} ->
          conn
          |> put_json_content_type(req)
          |> send_resp(200, body)

        {:rows, result} ->
          check_singular!(req, result.count)

          conn
          |> put_json_content_type(req)
          |> put_content_range(offset_of(ast), result.count, result.total)
          |> send_resp(200, result.body)
      end
    end)
  end

  @spec root(Plug.Conn.t()) :: Plug.Conn.t()
  def root(conn) do
    safely(conn, fn ->
      cache = SchemaCache.get()
      schema = request_context(conn).schema

      relations =
        for {{s, name}, _table} <- cache.tables, s == schema, do: name

      functions =
        for {{s, name}, _fn} <- cache.functions, s == schema, do: name

      body =
        Jason.encode!(%{
          relations: Enum.sort(relations),
          functions: Enum.sort(functions)
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end)
  end

  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  def not_found(conn) do
    render_error(conn, %Error{status: 404, code: "PGRST404", message: "Not found"})
  end

  defp mutate(conn, success_status, operation) do
    safely(conn, fn ->
      req = request_context(conn)
      ast = Parser.parse(conn.query_string)
      {payload, conn} = read_json_body(conn)
      returning = req.prefer.return || :minimal

      if payload == [] do
        conn
        |> put_json_content_type(req)
        |> send_resp(success_status, if(returning == :representation, do: "[]", else: ""))
      else
        result =
          operation.(req, ast, payload,
            returning: returning,
            singular: req.singular,
            auth: req.auth
          )

        respond_mutation(conn, req, success_status, returning, result)
      end
    end)
  end

  defp respond_mutation(conn, req, success_status, returning, result) do
    case returning do
      :minimal ->
        status = if success_status == 201, do: 201, else: 204

        conn
        |> put_content_range_mutation(result.count)
        |> send_resp(status, "")

      :representation ->
        check_singular!(req, result.count)

        conn
        |> put_json_content_type(req)
        |> put_content_range_mutation(result.count)
        |> send_resp(success_status, result.body)
    end
  end

  defp request_context(conn) do
    %{
      schema: request_schema(conn),
      prefer: parse_prefer(conn),
      singular: singular?(conn),
      auth: Auth.resolve(first_header(conn, "authorization"))
    }
  end

  defp request_schema(conn) do
    schemas = Postgrext.Config.get(:schemas) || Postgrext.Config.adapter().default_schemas()

    requested =
      first_header(conn, "accept-profile") || first_header(conn, "content-profile")

    case requested do
      nil ->
        hd(schemas)

      schema ->
        if schema in schemas do
          schema
        else
          raise Error.parse_error(
                  "The schema must be one of the following: #{Enum.join(schemas, ", ")}"
                )
        end
    end
  end

  defp parse_prefer(conn) do
    tokens =
      conn
      |> get_req_header("prefer")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)

    return =
      cond do
        "return=representation" in tokens -> :representation
        "return=minimal" in tokens -> :minimal
        true -> nil
      end

    count = if "count=exact" in tokens, do: :exact

    %{return: return, count: count}
  end

  defp singular?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, @object_media_type))
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp rpc_args(conn, arg_names) do
    case conn.method do
      "POST" ->
        {payload, conn} = read_json_body(conn)

        unless is_map(payload) do
          raise Error.parse_error("RPC arguments must be a JSON object")
        end

        {payload, conn}

      _get ->
        args =
          conn.query_string
          |> URI.decode_query()
          |> Map.filter(fn {key, _value} -> MapSet.member?(arg_names, key) end)

        {args, conn}
    end
  end

  defp read_json_body(conn) do
    {body, conn} = read_all_body(conn, "")

    case body do
      "" ->
        {%{}, conn}

      body ->
        case Jason.decode(body) do
          {:ok, decoded} -> {decoded, conn}
          {:error, _reason} -> raise Error.parse_error("Body is not valid JSON")
        end
    end
  end

  defp read_all_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {acc <> chunk, conn}
      {:more, chunk, conn} -> read_all_body(conn, acc <> chunk)
      {:error, _reason} -> raise Error.parse_error("Could not read request body")
    end
  end

  defp uniform_columns!(rows) do
    case rows do
      [] ->
        []

      [first | rest] ->
        unless Enum.all?(rows, &is_map/1) do
          raise Error.parse_error("Insert payload must be a JSON object or array of objects")
        end

        keys = first |> Map.keys() |> Enum.sort()

        unless Enum.all?(rest, fn row -> row |> Map.keys() |> Enum.sort() == keys end) do
          raise Error.parse_error("All object keys must match")
        end

        keys
    end
  end

  defp check_singular!(%{singular: true}, count) when count != 1 do
    raise Error.singular_cardinality(count)
  end

  defp check_singular!(_req, _count), do: :ok

  defp offset_of(ast) do
    Enum.find_value(ast.offset, 0, fn %{path: p, value: v} -> if p == [], do: v end)
  end

  defp put_content_range(conn, offset, count, total) do
    total_part = if total, do: Integer.to_string(total), else: "*"

    range =
      if count > 0 do
        "#{offset}-#{offset + count - 1}/#{total_part}"
      else
        "*/#{total_part}"
      end

    put_resp_header(conn, "content-range", range)
  end

  defp put_content_range_mutation(conn, affected) do
    put_resp_header(conn, "content-range", "*/#{affected}")
  end

  defp put_json_content_type(conn, %{singular: true}) do
    put_resp_content_type(conn, @object_media_type)
  end

  defp put_json_content_type(conn, _req) do
    put_resp_content_type(conn, "application/json")
  end

  defp safely(conn, fun) do
    fun.()
  rescue
    error in Error ->
      render_error(conn, error)

    error in Postgrex.Error ->
      render_error(conn, Error.from_postgrex(error))

    error in DBConnection.ConnectionError ->
      render_error(conn, %Error{status: 503, code: "PGRST001", message: error.message})
  end

  defp render_error(conn, %Error{} = error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.status, Jason.encode!(Error.to_json_map(error)))
  end
end
