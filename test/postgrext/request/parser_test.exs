defmodule Postgrext.Request.ParserTest do
  use ExUnit.Case, async: true

  alias Postgrext.Request.Parser

  test "empty query string yields the default AST" do
    assert %{select: [%{type: :all}], filters: [], order: [], limit: [], offset: []} =
             Parser.parse("")
  end

  test "select delegates to the select grammar" do
    %{select: [field, embed]} = Parser.parse("select=id,clients(name)")

    assert %{type: :field, name: "id"} = field
    assert %{type: :embed, name: "clients", select: [%{name: "name"}]} = embed
  end

  test "keeps raw params for RPC argument extraction" do
    assert %{raw_params: [{"a", "1"}, {"select", "name"}]} =
             Parser.parse("a=1&select=name", skip_keys: MapSet.new(["a"]))
  end

  describe "filter classification" do
    test "plain keys become root filters" do
      %{filters: [%{path: [], tree: tree}]} = Parser.parse("age=gte.18")
      assert %{type: :cond, field: "age", op: "gte", value: "18"} = tree
    end

    test "keeps repeated filters on the same column" do
      %{filters: filters} = Parser.parse("age=gte.18&age=lt.30")
      assert [%{tree: %{op: "gte"}}, %{tree: %{op: "lt"}}] = filters
    end

    test "dotted keys scope filters to embed paths" do
      %{filters: [%{path: ["clients"], tree: %{field: "name", op: "eq"}}]} =
        Parser.parse("clients.name=eq.acme")
    end

    test "skip_keys removes params from filter parsing" do
      ast = Parser.parse("a=1&age=gte.18", skip_keys: MapSet.new(["a"]))
      assert [%{tree: %{field: "age"}}] = ast.filters
    end

    test "ignores reserved passthrough keys" do
      assert %{filters: []} = Parser.parse("columns=a,b&on_conflict=id")
    end
  end

  describe "logic classification" do
    test "or becomes a root logic tree" do
      %{filters: [%{path: [], tree: tree}]} = Parser.parse("or=(age.gte.18,age.lt.5)")
      assert %{type: :logic, op: :or, negated: false, children: [_one, _two]} = tree
    end

    test "not.and becomes a negated logic tree" do
      %{filters: [%{path: [], tree: tree}]} = Parser.parse("not.and=(a.eq.1,b.eq.2)")
      assert %{type: :logic, op: :and, negated: true} = tree
    end

    test "dotted prefixes scope logic to embed paths" do
      %{filters: [%{path: ["clients"], tree: %{type: :logic, op: :or, negated: false}}]} =
        Parser.parse("clients.or=(id.eq.1,id.eq.2)")

      %{filters: [%{path: ["clients"], tree: %{type: :logic, op: :or, negated: true}}]} =
        Parser.parse("clients.not.or=(id.eq.1,id.eq.2)")
    end
  end

  describe "order, limit, offset" do
    test "parses order terms" do
      %{order: [%{path: [], terms: terms}]} = Parser.parse("order=age.desc.nullslast,name")

      assert [
               %{field: "age", dir: :desc, nulls: :last},
               %{field: "name", dir: nil, nulls: nil}
             ] = terms
    end

    test "rejects invalid order modifiers" do
      assert_raise Postgrext.Error, ~r/Invalid order modifier/, fn ->
        Parser.parse("order=age.sideways")
      end
    end

    test "parses limit and offset" do
      ast = Parser.parse("limit=10&offset=20")
      assert [%{path: [], value: 10}] = ast.limit
      assert [%{path: [], value: 20}] = ast.offset
    end

    test "scopes order and limit to embeds" do
      ast = Parser.parse("clients.order=name.asc&clients.limit=5")
      assert [%{path: ["clients"], terms: [%{field: "name", dir: :asc}]}] = ast.order
      assert [%{path: ["clients"], value: 5}] = ast.limit
    end

    test "rejects non-numeric limit" do
      assert_raise Postgrext.Error, ~r/Invalid value/, fn ->
        Parser.parse("limit=lots")
      end
    end
  end
end
