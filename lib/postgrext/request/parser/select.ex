defmodule Postgrext.Request.Parser.Select do
  @moduledoc """
  Grammar wrapper for the `select=` parameter.

  Returns a list of nodes:

    * `%{type: :all}` for `*`
    * `%{type: :field, name:, alias:, casts:}` for `alias:column::cast`
    * `%{type: :embed, name:, alias:, hint:, select:}` for
      `alias:relation!hint(items)`, nesting recursively
  """

  alias Postgrext.Error
  alias Postgrext.Request.Parser.Grammar

  @spec parse(String.t()) :: [map()]
  def parse(""), do: [%{type: :all}]

  def parse(value) do
    case Grammar.select(value) do
      {:ok, items, "", _context, _line, _offset} ->
        Enum.map(items, &ast_node/1)

      {:error, _reason, rest, _context, _line, _offset} ->
        raise select_error(rest)
    end
  end

  defp ast_node(:all), do: %{type: :all}

  defp ast_node({:field, parts}) do
    %{
      type: :field,
      name: parts[:name],
      alias: parts[:alias],
      casts: Keyword.get_values(parts, :cast)
    }
  end

  defp ast_node({:embed, parts}) do
    children = for part <- parts, embedded_node?(part), do: ast_node(part)

    %{
      type: :embed,
      name: parts[:name],
      alias: parts[:alias],
      hint: parts[:hint],
      select: children
    }
  end

  defp embedded_node?(:all), do: true
  defp embedded_node?({tag, _parts}), do: tag in [:field, :embed]

  defp select_error("," <> _rest) do
    Error.parse_error("Empty column name in select parameter")
  end

  defp select_error("(" <> _rest) do
    Error.parse_error("Unclosed embed in select parameter")
  end

  defp select_error(rest) do
    Error.parse_error("Unexpected '#{rest}' in select parameter")
  end
end
