defmodule Postgrext.Error do
  @moduledoc """
  Request-level error carrying an HTTP status and a PostgREST-style JSON body
  (`code`, `message`, `details`, `hint`). Postgres errors are mapped into this
  shape via `from_postgrex/1`.
  """

  defexception [:message, status: 400, code: "PGRST100", details: nil, hint: nil]

  @type t :: %__MODULE__{
          status: pos_integer(),
          code: String.t(),
          message: String.t(),
          details: String.t() | nil,
          hint: String.t() | nil
        }

  @spec parse_error(String.t()) :: t()
  def parse_error(message) do
    %__MODULE__{status: 400, code: "PGRST100", message: message}
  end

  @spec undefined_relation(String.t()) :: t()
  def undefined_relation(name) do
    %__MODULE__{
      status: 404,
      code: "PGRST205",
      message: "Could not find the table '#{name}' in the schema cache"
    }
  end

  @spec undefined_function(String.t()) :: t()
  def undefined_function(name) do
    %__MODULE__{
      status: 404,
      code: "PGRST202",
      message: "Could not find the function '#{name}' in the schema cache"
    }
  end

  @spec undefined_column(String.t(), String.t()) :: t()
  def undefined_column(relation, column) do
    %__MODULE__{
      status: 400,
      code: "PGRST204",
      message: "Could not find the '#{column}' column of '#{relation}' in the schema cache"
    }
  end

  @spec undefined_relationship(String.t(), String.t()) :: t()
  def undefined_relationship(parent, child) do
    %__MODULE__{
      status: 400,
      code: "PGRST200",
      message:
        "Could not find a relationship between '#{parent}' and '#{child}' in the schema cache"
    }
  end

  @spec ambiguous_relationship(String.t(), String.t()) :: t()
  def ambiguous_relationship(parent, child) do
    %__MODULE__{
      status: 300,
      code: "PGRST201",
      message:
        "Could not embed because more than one relationship was found for '#{parent}' and '#{child}'",
      hint: "Try disambiguating with an !hint naming the foreign key constraint or column"
    }
  end

  @spec rls_violation(String.t()) :: t()
  def rls_violation(relation) do
    %__MODULE__{
      status: 403,
      code: "42501",
      message: "new row violates row-level security policy for table \"#{relation}\""
    }
  end

  @spec jwt_error(String.t()) :: t()
  def jwt_error(message) do
    %__MODULE__{status: 401, code: "PGRST301", message: message}
  end

  @spec singular_cardinality(non_neg_integer()) :: t()
  def singular_cardinality(count) do
    %__MODULE__{
      status: 406,
      code: "PGRST116",
      message: "JSON object requested, multiple (or no) rows returned",
      details: "The result contains #{count} rows"
    }
  end

  @spec from_postgrex(Postgrex.Error.t()) :: t()
  def from_postgrex(%Postgrex.Error{postgres: %{code: _} = pg}) do
    sqlstate = pg[:pg_code] || sqlstate_from_atom(pg.code)

    %__MODULE__{
      status: status_for_sqlstate(sqlstate),
      code: sqlstate,
      message: pg[:message],
      details: pg[:detail],
      hint: pg[:hint]
    }
  end

  def from_postgrex(%Postgrex.Error{message: message}) do
    %__MODULE__{status: 500, code: "PGRST000", message: message || "database error"}
  end

  defp sqlstate_from_atom(code) when is_atom(code), do: Atom.to_string(code)
  defp sqlstate_from_atom(code) when is_binary(code), do: code

  defp status_for_sqlstate("23503"), do: 409
  defp status_for_sqlstate("23505"), do: 409
  defp status_for_sqlstate("23514"), do: 400
  defp status_for_sqlstate("23502"), do: 400
  defp status_for_sqlstate("42P01"), do: 404
  defp status_for_sqlstate("42883"), do: 404
  defp status_for_sqlstate("42703"), do: 400
  defp status_for_sqlstate("42501"), do: 403
  defp status_for_sqlstate("28000"), do: 403
  defp status_for_sqlstate("22023"), do: 401
  defp status_for_sqlstate("42704"), do: 401
  defp status_for_sqlstate("57014"), do: 504

  defp status_for_sqlstate(<<class::binary-size(2), _rest::binary>>)
       when class in ["08", "53", "57"],
       do: 503

  defp status_for_sqlstate(_other), do: 400

  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = error) do
    %{
      code: error.code,
      message: error.message,
      details: error.details,
      hint: error.hint
    }
  end
end
