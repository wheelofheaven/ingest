defmodule Curator.Parser.TextUtils do
  @moduledoc """
  Text normalization and cleanup utilities for OCR output.
  """

  @doc """
  Strips lines matching the given regex patterns from text.
  Used to remove page numbers, headers, footers, etc.
  """
  def strip_patterns(text, patterns) when is_list(patterns) do
    patterns
    |> Enum.reduce(text, fn pattern, acc ->
      regex = Regex.compile!(pattern, "m")
      Regex.replace(regex, acc, "")
    end)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  @doc """
  Splits text into paragraphs using the given separator pattern.
  Defaults to double-newline separation.
  """
  def split_paragraphs(text, separator \\ "\\n\\n") do
    regex = Regex.compile!(separator)

    text
    |> String.split(regex)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Normalizes unicode characters commonly mangled by OCR.
  """
  def normalize_unicode(text) do
    text
    # Ligatures
    |> String.replace("\uFB01", "fi")
    |> String.replace("\uFB02", "fl")
    |> String.replace("\uFB03", "ffi")
    |> String.replace("\uFB04", "ffl")
    # Smart quotes to straight quotes
    |> String.replace("\u201C", "\"")
    |> String.replace("\u201D", "\"")
    |> String.replace("\u2018", "'")
    |> String.replace("\u2019", "'")
    # Ellipsis
    |> String.replace("\u2026", "...")
    # En-dash to em-dash
    |> String.replace("\u2013", "\u2014")
  end

  @doc """
  Detects if a line is likely a page number.
  """
  def page_number?(line) do
    trimmed = String.trim(line)
    Regex.match?(~r/^\d{1,4}$/, trimmed)
  end

  @doc """
  Merges hyphenated words split across lines by OCR.
  """
  def merge_hyphenated_words(text) do
    Regex.replace(~r/(\w)-\n(\w)/, text, "\\1\\2")
  end

  @doc """
  Collapses multiple spaces into single spaces within lines.
  """
  def collapse_spaces(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r/ {2,}/, " "))
    |> Enum.join("\n")
  end
end
