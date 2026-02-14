defmodule PdfPipeline.Parser.Rules.ParagraphRules do
  @moduledoc """
  Paragraph boundary detection and splitting rules.
  """

  alias PdfPipeline.Parser.TextUtils
  alias PdfPipeline.Schema.Paragraph

  @doc """
  Splits chapter content into paragraph structs.

  Uses the configured separator pattern and applies strip patterns
  to clean up OCR artifacts before splitting.
  """
  def split_paragraphs(text, rules) do
    separator = Map.get(rules, "paragraph_separator", "\\n\\n")
    strip = Map.get(rules, "strip_patterns", [])

    text
    |> TextUtils.merge_hyphenated_words()
    |> TextUtils.normalize_unicode()
    |> TextUtils.collapse_spaces()
    |> TextUtils.strip_patterns(strip)
    |> TextUtils.split_paragraphs(separator)
    |> Enum.with_index(1)
    |> Enum.map(fn {text, idx} ->
      confidence = compute_confidence(text)

      Paragraph.new(%{
        n: idx,
        text: text,
        speaker: nil,
        confidence: confidence
      })
    end)
  end

  @doc """
  Computes a confidence score for a paragraph based on text quality heuristics.

  Lower confidence for:
  - Very short paragraphs (might be artifacts)
  - Paragraphs with excessive special characters
  - Paragraphs that look like headers or page numbers
  """
  def compute_confidence(text) do
    cond do
      String.length(text) < 10 -> 0.3
      String.length(text) < 30 -> 0.6
      ratio_special_chars(text) > 0.3 -> 0.5
      true -> 1.0
    end
  end

  defp ratio_special_chars(text) do
    total = String.length(text)

    if total == 0 do
      0.0
    else
      special =
        text
        |> String.graphemes()
        |> Enum.count(fn char ->
          not String.match?(char, ~r/[\p{L}\p{N}\s\.,;:!?\-'"()]/u)
        end)

      special / total
    end
  end
end
