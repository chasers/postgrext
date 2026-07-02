defmodule Postgrext.Request.Parser.FilterTest do
  use ExUnit.Case, async: true

  alias Postgrext.Request.Parser.Filter

  describe "condition/2" do
    test "parses simple operators" do
      assert %{type: :cond, field: "age", op: "gte", value: "18", negated: false, lang: nil} =
               Filter.condition("age", "gte.18")
    end

    test "parses negation" do
      assert %{op: "eq", negated: true} = Filter.condition("age", "not.eq.18")
    end

    test "keeps dots in values" do
      assert %{op: "gt", value: "1.5"} = Filter.condition("price", "gt.1.5")
    end

    test "unquotes quoted values" do
      assert %{value: ~s(hello "world")} =
               Filter.condition("greeting", ~S|eq."hello \"world\""|)
    end

    test "parses in lists with quoted values" do
      assert %{op: "in", value: ["alice", "b,ob", "carol"]} =
               Filter.condition("name", ~S|in.(alice,"b,ob",carol)|)
    end

    test "rejects in without a parenthesized list" do
      assert_raise Postgrext.Error, ~r/parenthesized list/, fn ->
        Filter.condition("name", "in.alice")
      end
    end

    test "parses is and rejects invalid is values" do
      assert %{op: "is", value: "null"} = Filter.condition("done", "is.null")

      assert_raise Postgrext.Error, ~r/`is` operator/, fn ->
        Filter.condition("done", "is.banana")
      end
    end

    test "parses full text search with language" do
      assert %{op: "fts", lang: "english", value: "cat"} =
               Filter.condition("body", "fts(english).cat")
    end

    test "rejects unknown operators" do
      assert_raise Postgrext.Error, ~r/Unknown filter operator/, fn ->
        Filter.condition("age", "around.18")
      end
    end
  end

  describe "logic/3" do
    test "parses conditions joined by or" do
      assert %{type: :logic, op: :or, negated: false, children: children} =
               Filter.logic("or", false, "(age.gte.18,age.lt.5)")

      assert [%{field: "age", op: "gte"}, %{field: "age", op: "lt"}] = children
    end

    test "parses nested and negated logic" do
      assert %{op: :and, children: [%{type: :cond}, nested]} =
               Filter.logic("and", false, "(done.is.true,not.or(age.eq.1,age.eq.2))")

      assert %{type: :logic, op: :or, negated: true, children: [_one, _two]} = nested
    end

    test "parses negated conditions inside logic" do
      assert %{children: [%{field: "age", op: "eq", negated: true}]} =
               Filter.logic("and", false, "(age.not.eq.1)")
    end

    test "parses in inside logic" do
      assert %{children: [%{op: "in", value: ["1", "2", "3"]}]} =
               Filter.logic("or", false, "(id.in.(1,2,3))")
    end

    test "parses multi-segment fields inside logic" do
      assert %{children: [%{field: "a.b", op: "eq", value: "1"}]} =
               Filter.logic("or", false, "(a.b.eq.1)")
    end

    test "rejects logic without parens" do
      assert_raise Postgrext.Error, ~r/parenthesized/, fn ->
        Filter.logic("or", false, "age.gte.18")
      end
    end

    test "rejects empty logic" do
      assert_raise Postgrext.Error, ~r/at least one condition/, fn ->
        Filter.logic("or", false, "()")
      end
    end

    test "rejects conditions without a field" do
      assert_raise Postgrext.Error, ~r/Could not parse logic tree/, fn ->
        Filter.logic("or", false, "(eq.1)")
      end
    end

    test "rejects unparseable elements" do
      assert_raise Postgrext.Error, ~r/Could not parse logic tree/, fn ->
        Filter.logic("or", false, "(banana)")
      end
    end
  end
end
