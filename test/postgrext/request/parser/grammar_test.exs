defmodule Postgrext.Request.Parser.GrammarTest do
  use ExUnit.Case, async: true

  alias Postgrext.Request.Parser.Grammar

  test "select tags fields, casts, and embeds" do
    {:ok, items, "", _context, _line, _offset} = Grammar.select("id,who:clients!fk(name),n::text")

    assert [
             {:field, [name: "id"]},
             {:embed,
              [{:alias, "who"}, {:name, "clients"}, {:hint, "fk"}, {:field, [name: "name"]}]},
             {:field, [name: "n", cast: "text"]}
           ] = items
  end

  test "select supports casts with type modifiers" do
    {:ok, [{:field, parts}], "", _context, _line, _offset} =
      Grammar.select("budget::numeric(10,2)")

    assert parts[:cast] == "numeric(10,2)"
  end

  test "condition_value tags negation, operator, language, and value" do
    {:ok, parts, "", _context, _line, _offset} = Grammar.condition_value("not.fts(english).cat")
    assert parts == [negated: true, op: "fts", lang: "english", value: "cat"]
  end

  test "logic_tree nests logic and keeps dotted values intact" do
    {:ok, elements, "", _context, _line, _offset} =
      Grammar.logic_tree("(price.gt.1.5,not.or(a.b.eq.x))")

    assert [
             {:cond, [seg: "price", op: "gt", value: "1.5"]},
             {:logic,
              [
                {:negated, true},
                {:logic_op, "or"},
                {:cond, [seg: "a", seg: "b", op: "eq", value: "x"]}
              ]}
           ] = elements
  end

  test "in_list distinguishes quoted from raw elements" do
    {:ok, elements, "", _context, _line, _offset} = Grammar.in_list(~S|(alice,"b,ob", carol)|)
    assert elements == [raw: "alice", quoted: "b,ob", raw: "carol"]
  end

  test "order splits terms and segments" do
    {:ok, terms, "", _context, _line, _offset} = Grammar.order("age.desc.nullslast,name")
    assert terms == [term: ["age", "desc", "nullslast"], term: ["name"]]
  end

  test "quoted unescapes a fully quoted string" do
    {:ok, [value], "", _context, _line, _offset} = Grammar.quoted(~S|"a\"b"|)
    assert value == ~s(a"b)
  end
end
