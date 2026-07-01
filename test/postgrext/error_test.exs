defmodule Postgrext.ErrorTest do
  use ExUnit.Case, async: true

  alias Postgrext.Error

  test "maps unique violations to 409" do
    error =
      Error.from_postgrex(%Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          pg_code: "23505",
          message: "duplicate key",
          detail: "Key (id)=(1) already exists.",
          hint: nil
        }
      })

    assert %{status: 409, code: "23505", message: "duplicate key"} = error
    assert error.details == "Key (id)=(1) already exists."
  end

  test "maps undefined table to 404 and insufficient privilege to 403" do
    assert %{status: 404} =
             Error.from_postgrex(%Postgrex.Error{
               postgres: %{code: :undefined_table, pg_code: "42P01", message: "no table"}
             })

    assert %{status: 403} =
             Error.from_postgrex(%Postgrex.Error{
               postgres: %{code: :insufficient_privilege, pg_code: "42501", message: "denied"}
             })
  end

  test "maps connection-class errors to 503 and unknown codes to 400" do
    assert %{status: 503} =
             Error.from_postgrex(%Postgrex.Error{
               postgres: %{code: :too_many_connections, pg_code: "53300", message: "full"}
             })

    assert %{status: 400} =
             Error.from_postgrex(%Postgrex.Error{
               postgres: %{code: :whatever, pg_code: "22012", message: "division by zero"}
             })
  end

  test "renders a json map with null fields" do
    map = Error.to_json_map(Error.parse_error("nope"))
    assert map == %{code: "PGRST100", message: "nope", details: nil, hint: nil}
  end

  test "singular cardinality error is 406" do
    assert %{status: 406, code: "PGRST116"} = Error.singular_cardinality(3)
  end
end
