defmodule Postgrext.Adapters.SQLite.Connection do
  @moduledoc """
  Owns the SQLite database handle and serializes all access through one
  process. Transactions run inside the server, so a transaction body executes
  its queries directly against the handle without interleaving with other
  callers. SQLite errors are normalized into `Postgrext.Error`.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Postgrext.Error

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec query!(String.t(), [term()]) :: %{
          rows: [[term()]],
          num_rows: non_neg_integer(),
          changes: non_neg_integer()
        }
  def query!(sql, params) when is_binary(sql) do
    __MODULE__
    |> GenServer.call({:query, sql, params}, :infinity)
    |> unwrap!()
  end

  @spec query!(reference(), String.t(), [term()]) :: %{
          rows: [[term()]],
          num_rows: non_neg_integer(),
          changes: non_neg_integer()
        }
  def query!(db, sql, params) when is_reference(db) do
    run(db, sql, params) |> unwrap!()
  end

  @spec transaction((reference() -> result)) :: result when result: term()
  def transaction(fun) do
    case GenServer.call(__MODULE__, {:transaction, fun}, :infinity) do
      {:ok, value} -> value
      {:raised, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok, db} = Sqlite3.open(Keyword.fetch!(opts, :database))
    :ok = Sqlite3.execute(db, "pragma foreign_keys = on")
    {:ok, %{db: db}}
  end

  @impl GenServer
  def handle_call({:query, sql, params}, _from, state) do
    {:reply, run(state.db, sql, params), state}
  end

  def handle_call({:transaction, fun}, _from, state) do
    :ok = Sqlite3.execute(state.db, "begin")

    try do
      value = fun.(state.db)
      :ok = Sqlite3.execute(state.db, "commit")
      {:reply, {:ok, value}, state}
    rescue
      exception ->
        Sqlite3.execute(state.db, "rollback")
        {:reply, {:raised, exception, __STACKTRACE__}, state}
    end
  end

  defp run(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(statement, params) do
      try do
        case collect_rows(db, statement, []) do
          {:ok, rows} ->
            {:ok, changes} = Sqlite3.changes(db)
            {:ok, %{rows: rows, num_rows: length(rows), changes: changes}}

          {:error, reason} ->
            {:error, reason}
        end
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  defp collect_rows(db, statement, acc) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> collect_rows(db, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
      :busy -> collect_rows(db, statement, acc)
    end
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: raise(normalize_error(reason))

  defp normalize_error(reason) do
    message = to_string(reason)

    cond do
      message =~ "UNIQUE constraint failed" ->
        %Error{status: 409, code: "SQLITE_CONSTRAINT_UNIQUE", message: message}

      message =~ "FOREIGN KEY constraint failed" ->
        %Error{status: 409, code: "SQLITE_CONSTRAINT_FOREIGNKEY", message: message}

      message =~ "constraint failed" ->
        %Error{status: 400, code: "SQLITE_CONSTRAINT", message: message}

      message =~ "no such table" ->
        %Error{status: 404, code: "SQLITE_ERROR", message: message}

      message =~ "no such column" ->
        %Error{status: 400, code: "SQLITE_ERROR", message: message}

      true ->
        %Error{status: 400, code: "SQLITE_ERROR", message: message}
    end
  end
end
