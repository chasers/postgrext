defmodule Postgrext.Controller do
  @moduledoc """
  Executes parsed requests: resolves auth, builds SQL, runs it inside a
  transaction with the request role applied via `set_config`, and renders
  PostgREST-style responses (JSON bodies, `Content-Range`, `Prefer` handling).
  """

  import Plug.Conn

  alias Postgrext.Auth
  alias Postgrext.Error
  alias Postgrext.Query.Builder
  alias Postgrext.Request.Parser
  alias Postgrext.SchemaCache

  @object_media_type "application/vnd.pgrst.object+json"

  @spec read(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def read(conn, relation) do
    safely(conn, fn ->
      req = request_context(conn)
      ast = Parser.parse(conn.query_string)
      cache = SchemaCache.get()

      {sql, params} = Builder.read(cache, req.schema, relation, ast, singular: req.singular)

      count_query =
        if req.prefer.count == :exact do
          Builder.count(cache, req.schema, relation, ast)
        end

      {body, page_count, total} =
        transact(req, fn conn_pid ->
          [[body, page_count]] = query!(conn_pid, sql, params).rows

          total =
            case count_query do
              nil -> nil
              {count_sql, count_params} -> hd(hd(query!(conn_pid, count_sql, count_params).rows))
            end

          {body, page_count, total}
        end)

      check_singular!(req, page_count)

      conn
      |> put_json_content_type(req)
      |> put_content_range(offset_of(ast), page_count, total)
      |> send_resp(200, body)
    end)
  end

  @spec create(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create(conn, relation) do
    mutate(conn, relation, 201, fn cache, req, ast, payload ->
      rows = List.wrap(payload)
      columns = uniform_columns!(rows)

      Builder.insert(cache, req.schema, relation, ast, Jason.encode!(rows), columns,
        returning: req.prefer.return || :minimal,
        singular: req.singular
      )
    end)
  end

  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, relation) do
    mutate(conn, relation, 200, fn cache, req, ast, payload ->
      unless is_map(payload) do
        raise Error.parse_error("PATCH requires a JSON object body")
      end

      Builder.update(cache, req.schema, relation, ast, Jason.encode!(payload), Map.keys(payload),
        returning: req.prefer.return || :minimal,
        singular: req.singular
      )
    end)
  end

  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, relation) do
    safely(conn, fn ->
      req = request_context(conn)
      ast = Parser.parse(conn.query_string)
      cache = SchemaCache.get()
      returning = req.prefer.return || :minimal

      {sql, params} =
        Builder.delete(cache, req.schema, relation, ast,
          returning: returning,
          singular: req.singular
        )

      respond_mutation(conn, req, 200, returning, fn conn_pid ->
        query!(conn_pid, sql, params)
      end)
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

      {sql, params, kind} =
        Builder.rpc(cache, req.schema, fname, ast, args, singular: req.singular)

      case kind do
        :void ->
          transact(req, fn conn_pid -> query!(conn_pid, sql, params) end)
          send_resp(conn, 204, "")

        :scalar ->
          [[body, _count]] = transact(req, fn conn_pid -> query!(conn_pid, sql, params) end).rows

          conn
          |> put_json_content_type(req)
          |> send_resp(200, body)

        :rows ->
          [[body, page_count]] =
            transact(req, fn conn_pid -> query!(conn_pid, sql, params) end).rows

          check_singular!(req, page_count)

          conn
          |> put_json_content_type(req)
          |> put_content_range(offset_of(ast), page_count, nil)
          |> send_resp(200, body)
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

  defp mutate(conn, _relation, success_status, build) do
    safely(conn, fn ->
      req = request_context(conn)
      ast = Parser.parse(conn.query_string)
      cache = SchemaCache.get()
      {payload, conn} = read_json_body(conn)

      if payload == [] do
        conn
        |> put_json_content_type(req)
        |> send_resp(success_status, if(req.prefer.return == :representation, do: "[]", else: ""))
      else
        {sql, params} = build.(cache, req, ast, payload)
        returning = req.prefer.return || :minimal

        respond_mutation(conn, req, success_status, returning, fn conn_pid ->
          query!(conn_pid, sql, params)
        end)
      end
    end)
  end

  defp respond_mutation(conn, req, success_status, returning, run) do
    result = transact(req, run)

    case returning do
      :minimal ->
        status = if success_status == 201, do: 201, else: 204

        conn
        |> put_content_range_mutation(result.num_rows)
        |> send_resp(status, "")

      :representation ->
        [[body, page_count]] = result.rows
        check_singular!(req, page_count)

        conn
        |> put_json_content_type(req)
        |> put_content_range_mutation(page_count)
        |> send_resp(success_status, body)
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
    schemas = Postgrext.Config.get(:schemas) || ["public"]

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

  defp transact(req, fun) do
    result =
      Postgrex.transaction(Postgrext.DB, fn conn_pid ->
        apply_role(conn_pid, req.auth)
        fun.(conn_pid)
      end)

    case result do
      {:ok, value} ->
        value

      {:error, :rollback} ->
        raise %Error{status: 500, code: "PGRST000", message: "transaction rolled back"}
    end
  end

  defp apply_role(conn_pid, %{role: nil}), do: {:ok, conn_pid}

  defp apply_role(conn_pid, %{role: role, claims: claims}) do
    query!(
      conn_pid,
      "select set_config('role', $1, true), set_config('request.jwt.claims', $2, true)",
      [role, Jason.encode!(claims)]
    )
  end

  defp query!(conn_pid, sql, params) do
    Postgrex.query!(conn_pid, sql, params)
  end

  defp check_singular!(%{singular: true}, page_count) when page_count != 1 do
    raise Error.singular_cardinality(page_count)
  end

  defp check_singular!(_req, _page_count), do: :ok

  defp offset_of(ast) do
    Enum.find_value(ast.offset, 0, fn %{path: p, value: v} -> if p == [], do: v end)
  end

  defp put_content_range(conn, offset, page_count, total) do
    total_part = if total, do: Integer.to_string(total), else: "*"

    range =
      if page_count > 0 do
        "#{offset}-#{offset + page_count - 1}/#{total_part}"
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
