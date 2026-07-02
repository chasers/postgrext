defmodule Postgrext.Request.Parser.SelectTest do
  use ExUnit.Case, async: true

  alias Postgrext.Request.Parser.Select

  test "empty select means all columns" do
    assert Select.parse("") == [%{type: :all}]
  end

  test "parses a plain column list" do
    assert [
             %{type: :field, name: "id", alias: nil, casts: []},
             %{type: :field, name: "name", alias: nil, casts: []}
           ] = Select.parse("id,name")
  end

  test "parses star mixed with fields" do
    assert [%{type: :all}, %{type: :field, name: "id"}] = Select.parse("*,id")
  end

  test "parses aliases and casts" do
    assert [%{name: "name", alias: "fullName", casts: ["text"]}] =
             Select.parse("fullName:name::text")
  end

  test "parses a cast without an alias" do
    assert [%{name: "id", alias: nil, casts: ["text"]}] = Select.parse("id::text")
  end

  test "parses chained casts" do
    assert [%{name: "id", casts: ["text", "integer"]}] = Select.parse("id::text::integer")
  end

  test "parses embedded resources" do
    assert [%{type: :embed, name: "clients", alias: nil, hint: nil, select: children}] =
             Select.parse("clients(id,name)")

    assert [%{name: "id"}, %{name: "name"}] = children
  end

  test "parses nested embeds with aliases and hints" do
    assert [%{type: :embed, name: "clients", alias: "who", hint: "clients_fk", select: children}] =
             Select.parse("who:clients!clients_fk(name,projects(id))")

    assert [%{type: :field, name: "name"}, %{type: :embed, name: "projects"}] = children
  end

  test "rejects unbalanced parens" do
    assert_raise Postgrext.Error, ~r/Unclosed embed/, fn ->
      Select.parse("clients(id")
    end
  end

  test "rejects trailing garbage" do
    assert_raise Postgrext.Error, ~r/Unexpected/, fn ->
      Select.parse("clients(id))")
    end
  end

  test "rejects empty column names" do
    assert_raise Postgrext.Error, ~r/Empty column name/, fn ->
      Select.parse("id,")
    end
  end

  test "parses casts with type modifiers" do
    assert [%{name: "budget", casts: ["numeric(10,2)"]}] = Select.parse("budget::numeric(10,2)")
  end

  test "rejects malformed casts" do
    assert_raise Postgrext.Error, ~r/Unexpected ';xt'/, fn ->
      Select.parse("id::te;xt")
    end
  end
end
