defmodule Postgrext.Request.Parser.Grammar do
  @moduledoc """
  NimbleParsec grammars for PostgREST's query syntax, compiled to single-pass
  binary matching. These parsers are purely structural; semantic validation
  (operator membership rules, `is` values) lives in the wrapper modules.

  Entry points: `select/1`, `condition_value/1`, `logic_tree/1`, `in_list/1`,
  `order/1`, and `quoted/1`.
  """

  import NimbleParsec

  @simple_ops ~w(eq neq ne gt gte lt lte like ilike match imatch is in cs cd ov sl sr nxr nxl adj)
  @fts_ops ~w(fts plfts phfts wfts)
  @ops @simple_ops ++ @fts_ops

  @spec fts_ops() :: [String.t()]
  def fts_ops, do: @fts_ops

  whitespace = ignore(optional(ascii_string([?\s], min: 1)))

  quoted_string =
    ignore(ascii_char([?"]))
    |> repeat(
      choice([
        ignore(ascii_char([?\\])) |> utf8_char([]),
        utf8_char(not: ?", not: ?\\)
      ])
    )
    |> ignore(ascii_char([?"]))
    |> reduce({List, :to_string, []})

  quoted_span =
    ascii_char([?"])
    |> repeat(
      choice([
        ascii_char([?\\]) |> utf8_char([]),
        utf8_char(not: ?", not: ?\\)
      ])
    )
    |> ascii_char([?"])

  op_choice =
    @ops
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.map(&string/1)
    |> choice()

  lang =
    ignore(ascii_char([?(]))
    |> utf8_string([not: ?)], min: 0)
    |> ignore(ascii_char([?)]))

  select_name = utf8_string([not: ?,, not: ?(, not: ?), not: ?:, not: ?!], min: 1)

  select_alias =
    select_name
    |> ignore(ascii_char([?:]))
    |> lookahead_not(ascii_char([?:]))
    |> unwrap_and_tag(:alias)

  cast =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?\s]))
    |> optional(
      ascii_char([?(])
      |> ascii_string([?0..?9], min: 1)
      |> optional(ascii_char([?,]) |> ascii_string([?0..?9], min: 1))
      |> ascii_char([?)])
    )
    |> optional(string("[]"))
    |> reduce({List, :to_string, []})

  select_star = string("*") |> replace(:all)

  select_embed =
    optional(select_alias)
    |> concat(select_name |> unwrap_and_tag(:name))
    |> optional(ignore(ascii_char([?!])) |> concat(select_name |> unwrap_and_tag(:hint)))
    |> ignore(ascii_char([?(]))
    |> parsec(:select_items)
    |> ignore(ascii_char([?)]))
    |> tag(:embed)

  select_field =
    optional(select_alias)
    |> concat(select_name |> unwrap_and_tag(:name))
    |> repeat(ignore(string("::")) |> concat(cast |> unwrap_and_tag(:cast)))
    |> tag(:field)

  select_item = choice([select_star, select_embed, select_field])

  defcombinatorp(
    :select_items,
    select_item |> repeat(ignore(ascii_char([?,])) |> concat(select_item))
  )

  defparsec(:select, parsec(:select_items) |> eos())

  defparsec(
    :condition_value,
    optional(string("not.") |> replace(true) |> unwrap_and_tag(:negated))
    |> concat(op_choice |> unwrap_and_tag(:op))
    |> optional(lang |> unwrap_and_tag(:lang))
    |> choice([
      ignore(ascii_char([?.])) |> concat(utf8_string([], min: 0) |> unwrap_and_tag(:value)),
      eos()
    ])
  )

  in_element =
    whitespace
    |> choice([
      quoted_string |> unwrap_and_tag(:quoted) |> concat(whitespace),
      utf8_string([not: ?,, not: ?), not: ?(], min: 0) |> unwrap_and_tag(:raw)
    ])

  defparsec(
    :in_list,
    ignore(ascii_char([?(]))
    |> concat(in_element)
    |> repeat(ignore(ascii_char([?,])) |> concat(in_element))
    |> ignore(ascii_char([?)]))
    |> eos()
  )

  defcombinatorp(
    :balanced_span,
    ascii_char([?(])
    |> repeat(
      choice([
        parsec(:balanced_span),
        quoted_span,
        utf8_char(not: ?(, not: ?), not: ?")
      ])
    )
    |> ascii_char([?)])
  )

  logic_raw_value =
    times(
      choice([
        parsec(:balanced_span),
        quoted_span,
        utf8_char(not: ?,, not: ?(, not: ?), not: ?")
      ]),
      min: 1
    )
    |> reduce({List, :to_string, []})

  logic_terminator = choice([ascii_char([?,]), ascii_char([?)]), eos()])

  operator_boundary =
    optional(string("not."))
    |> concat(op_choice)
    |> optional(lang)
    |> choice([ascii_char([?.]), lookahead(logic_terminator)])

  logic_field_segment =
    lookahead_not(operator_boundary)
    |> utf8_string([not: ?., not: ?,, not: ?(, not: ?), not: ?"], min: 1)

  logic_condition =
    times(logic_field_segment |> unwrap_and_tag(:seg) |> ignore(ascii_char([?.])), min: 1)
    |> optional(string("not.") |> replace(true) |> unwrap_and_tag(:negated))
    |> concat(op_choice |> unwrap_and_tag(:op))
    |> optional(lang |> unwrap_and_tag(:lang))
    |> choice([
      ignore(ascii_char([?.])) |> concat(logic_raw_value |> unwrap_and_tag(:value)),
      lookahead(logic_terminator)
    ])
    |> tag(:cond)

  nested_logic =
    optional(string("not.") |> replace(true) |> unwrap_and_tag(:negated))
    |> concat(choice([string("and"), string("or")]) |> unwrap_and_tag(:logic_op))
    |> ignore(ascii_char([?(]))
    |> parsec(:logic_elements)
    |> ignore(ascii_char([?)]))
    |> tag(:logic)

  logic_element = whitespace |> choice([nested_logic, logic_condition])

  defcombinatorp(
    :logic_elements,
    logic_element |> repeat(ignore(ascii_char([?,])) |> concat(logic_element))
  )

  defparsec(
    :logic_tree,
    ignore(ascii_char([?(])) |> parsec(:logic_elements) |> ignore(ascii_char([?)])) |> eos()
  )

  order_segment = utf8_string([not: ?., not: ?,, not: ?\s], min: 1)

  order_term =
    whitespace
    |> concat(order_segment)
    |> repeat(ignore(ascii_char([?.])) |> concat(order_segment))
    |> concat(whitespace)
    |> tag(:term)

  defparsec(
    :order,
    order_term |> repeat(ignore(ascii_char([?,])) |> concat(order_term)) |> eos()
  )

  defparsec(:quoted, quoted_string |> eos())
end
