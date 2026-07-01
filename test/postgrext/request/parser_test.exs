defmodule Postgrext.Request.ParserTest do
  use ExUnit.Case, async: true

  alias Postgrext.Request.Parser

  describe "select" do
    test "defaults to all columns" do
      assert %{select: [%{type: :all}]} = Parser.parse("")
    end

    test "parses a plain column list" do
      %{select: select} = Parser.parse("select=id,name")

      assert [
               %{type: :field, name: "id", alias: nil, casts: []},
               %{type: :field, name: "name", alias: nil, casts: []}
             ] = select
    end

    test "parses star mixed with fields" do
      %{select: [%{type: :all}, %{type: :field, name: "id"}]} = Parser.parse("select=*,id")
    end

    test "parses aliases and casts" do
      %{select: [field]} = Parser.parse("select=fullName:name::text")
      assert %{name: "name", alias: "fullName", casts: ["text"]} = field
    end

    test "parses a cast without an alias" do
      %{select: [field]} = Parser.parse("select=id::text")
      assert %{name: "id", alias: nil, casts: ["text"]} = field
    end

    test "parses embedded resources" do
      %{select: [id, embed]} = Parser.parse("select=id,clients(id,name)")

      assert %{type: :field, name: "id"} = id
      assert %{type: :embed, name: "clients", alias: nil, hint: nil} = embed
      assert [%{name: "id"}, %{name: "name"}] = embed.select
    end

    test "parses nested embeds with aliases and hints" do
      %{select: [embed]} = Parser.parse("select=who:clients!clients_fk(name,projects(id))")

      assert %{type: :embed, name: "clients", alias: "who", hint: "clients_fk"} = embed
      assert [%{type: :field, name: "name"}, %{type: :embed, name: "projects"}] = embed.select
    end

    test "rejects unbalanced parens" do
      assert_raise Postgrext.Error, ~r/Unclosed embed/, fn ->
        Parser.parse("select=clients(id")
      end
    end
  end

  describe "filters" do
    test "parses simple operators" do
      %{filters: [%{path: [], tree: tree}]} = Parser.parse("age=gte.18")
      assert %{type: :cond, field: "age", op: "gte", value: "18", negated: false} = tree
    end

    test "keeps repeated filters on the same column" do
      %{filters: filters} = Parser.parse("age=gte.18&age=lt.30")
      assert [%{tree: %{op: "gte"}}, %{tree: %{op: "lt"}}] = filters
    end

    test "parses negation" do
      %{filters: [%{tree: tree}]} = Parser.parse("age=not.eq.18")
      assert %{op: "eq", negated: true} = tree
    end

    test "parses values containing dots" do
      %{filters: [%{tree: tree}]} = Parser.parse("price=gt.1.5")
      assert %{op: "gt", value: "1.5"} = tree
    end

    test "parses in lists with quoted values" do
      %{filters: [%{tree: tree}]} = Parser.parse(~S|name=in.(alice,"b,ob",carol)|)
      assert %{op: "in", value: ["alice", "b,ob", "carol"]} = tree
    end

    test "parses is" do
      %{filters: [%{tree: tree}]} = Parser.parse("done=is.null")
      assert %{op: "is", value: "null"} = tree
    end

    test "rejects invalid is values" do
      assert_raise Postgrext.Error, ~r/`is` operator/, fn ->
        Parser.parse("done=is.banana")
      end
    end

    test "parses full text search with language" do
      %{filters: [%{tree: tree}]} = Parser.parse("body=fts(english).cat")
      assert %{op: "fts", lang: "english", value: "cat"} = tree
    end

    test "scopes filters to embed paths" do
      %{filters: [%{path: ["clients"], tree: %{field: "name", op: "eq"}}]} =
        Parser.parse("clients.name=eq.acme")
    end

    test "rejects unknown operators" do
      assert_raise Postgrext.Error, ~r/Unknown filter operator/, fn ->
        Parser.parse("age=around.18")
      end
    end

    test "skips keys in skip_keys" do
      ast = Parser.parse("a=1&age=gte.18", skip_keys: MapSet.new(["a"]))
      assert [%{tree: %{field: "age"}}] = ast.filters
    end
  end

  describe "logic trees" do
    test "parses or" do
      %{filters: [%{path: [], tree: tree}]} = Parser.parse("or=(age.gte.18,age.lt.5)")

      assert %{type: :logic, op: :or, negated: false} = tree
      assert [%{field: "age", op: "gte"}, %{field: "age", op: "lt"}] = tree.children
    end

    test "parses nested and negated logic" do
      %{filters: [%{tree: tree}]} =
        Parser.parse("and=(done.is.true,not.or(age.eq.1,age.eq.2))")

      assert %{op: :and, children: [%{type: :cond}, nested]} = tree
      assert %{type: :logic, op: :or, negated: true, children: [_one, _two]} = nested
    end

    test "parses negated conditions inside logic" do
      %{filters: [%{tree: %{children: [child]}}]} = Parser.parse("and=(age.not.eq.1)")
      assert %{field: "age", op: "eq", negated: true} = child
    end

    test "parses in inside logic" do
      %{filters: [%{tree: %{children: [child]}}]} = Parser.parse("or=(id.in.(1,2,3))")
      assert %{op: "in", value: ["1", "2", "3"]} = child
    end

    test "scopes logic to embed paths" do
      %{filters: [%{path: ["clients"], tree: %{type: :logic}}]} =
        Parser.parse("clients.or=(id.eq.1,id.eq.2)")
    end

    test "rejects logic without parens" do
      assert_raise Postgrext.Error, ~r/parenthesized/, fn ->
        Parser.parse("or=age.gte.18")
      end
    end
  end

  describe "order, limit, offset" do
    test "parses order terms" do
      %{order: [%{path: [], terms: terms}]} =
        Parser.parse("order=age.desc.nullslast,name")

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
