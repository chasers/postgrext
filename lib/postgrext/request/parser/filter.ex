defmodule Postgrext.Request.Parser.Filter do
  @moduledoc """
  Grammar wrapper for horizontal filters and logic trees.

  A condition value looks like `[not.]op[(language)].value` and parses to
  `%{type: :cond, field:, op:, negated:, lang:, value:}`; `and`/`or`
  parameters parse to `%{type: :logic, op:, negated:, children:}` with
  conditions and nested logic as children.
  """

  alias Postgrext.Error
  alias Postgrext.Request.Parser.Grammar

  @spec condition(String.t(), String.t()) :: map()
  def condition(field, value) do
    case Grammar.condition_value(value) do
      {:ok, parts, "", _context, _line, _offset} ->
        build_condition(field, parts)

      {:error, _reason, _rest, _context, _line, _offset} ->
        raise unknown_operator(value)
    end
  end

  @spec logic(String.t(), boolean(), String.t()) :: map()
  def logic(op, negated, value) when op in ["and", "or"] do
    case Grammar.logic_tree(value) do
      {:ok, elements, "", _context, _line, _offset} ->
        %{
          type: :logic,
          op: logic_op(op),
          negated: negated,
          children: Enum.map(elements, &element/1)
        }

      {:error, _reason, rest, _context, _line, _offset} ->
        raise logic_error(op, value, rest)
    end
  end

  defp element({:logic, parts}) do
    children = for part <- parts, elem(part, 0) in [:cond, :logic], do: element(part)

    %{
      type: :logic,
      op: logic_op(parts[:logic_op]),
      negated: Keyword.get(parts, :negated, false),
      children: children
    }
  end

  defp element({:cond, parts}) do
    field = parts |> Keyword.get_values(:seg) |> Enum.join(".")

    parts =
      Keyword.update(parts, :value, "", &String.trim_trailing/1)

    build_condition(field, parts)
  end

  defp build_condition(field, parts) do
    op = parts[:op]
    lang = validate_lang!(op, parts[:lang])

    %{
      type: :cond,
      field: field,
      op: op,
      negated: Keyword.get(parts, :negated, false),
      lang: lang,
      value: condition_value(op, Keyword.get(parts, :value, ""))
    }
  end

  defp condition_value("in", raw) do
    case Grammar.in_list(raw) do
      {:ok, elements, "", _context, _line, _offset} ->
        Enum.map(elements, fn
          {:quoted, value} -> value
          {:raw, value} -> String.trim(value)
        end)

      {:error, _reason, _rest, _context, _line, _offset} ->
        raise Error.parse_error("`in` operator requires a parenthesized list")
    end
  end

  defp condition_value("is", raw) do
    unless raw in ~w(null true false unknown) do
      raise Error.parse_error("Invalid value '#{raw}' for `is` operator")
    end

    raw
  end

  defp condition_value(_op, raw), do: maybe_unquote(raw)

  defp maybe_unquote(<<?", _rest::binary>> = raw) do
    case Grammar.quoted(raw) do
      {:ok, [unquoted], "", _context, _line, _offset} -> unquoted
      {:error, _reason, _rest, _context, _line, _offset} -> raw
    end
  end

  defp maybe_unquote(raw), do: raw

  defp validate_lang!(_op, nil), do: nil

  defp validate_lang!(op, lang) do
    if op in Grammar.fts_ops() do
      lang
    else
      raise Error.parse_error("Unknown filter operator '#{op}(#{lang})'")
    end
  end

  defp logic_op("and"), do: :and
  defp logic_op("or"), do: :or

  defp logic_error(op, value, rest) do
    cond do
      not String.starts_with?(value, "(") ->
        Error.parse_error("`#{op}` requires a parenthesized list of conditions")

      value == "()" ->
        Error.parse_error("`#{op}` requires at least one condition")

      true ->
        Error.parse_error("Could not parse logic tree at '#{rest}'")
    end
  end

  defp unknown_operator(value) do
    token =
      case value do
        "not." <> rest -> rest
        rest -> rest
      end
      |> String.split(".", parts: 2)
      |> hd()

    Error.parse_error("Unknown filter operator '#{token}'")
  end
end
