defmodule PdfPipeline.Parser.RuleEngine do
  @moduledoc """
  Orchestrates rule-based parsing of OCR text into structured book data.

  Loads rule configurations from JSON files and applies them sequentially:
  1. Strip OCR artifacts (page numbers, headers)
  2. Split into chapters
  3. Split chapters into paragraphs
  4. Detect speakers
  """

  alias PdfPipeline.Parser.Rules.{ChapterRules, ParagraphRules, SpeakerRules}
  alias PdfPipeline.Schema.{Book, Chapter}

  require Logger

  @rules_dir "priv/rules"

  @doc """
  Parses OCR text into a Book struct using the specified rule profile.

  ## Parameters
  - `text` — Raw OCR output text
  - `metadata` — Map with `:slug`, `:code`, `:primary_lang`, and optional `:title`
  - `profile` — Rule profile name (default: "default")

  ## Returns
  - `{:ok, %Book{}}` — Parsed book struct
  - `{:error, reason}` — Error
  """
  def parse(text, metadata, profile \\ "default") do
    with {:ok, rules} <- load_rules(profile) do
      Logger.info("Parsing with rule profile: #{profile}")

      chapters = parse_chapters(text, rules)

      book =
        Book.new(%{
          slug: metadata[:slug],
          code: metadata[:code],
          primary_lang: metadata[:primary_lang],
          titles: %{metadata[:primary_lang] => metadata[:title] || ""},
          publication_year: metadata[:publication_year],
          chapters: chapters
        })
        |> Book.assign_ref_ids()

      Logger.info("Parsed #{Book.chapter_count(book)} chapters, #{Book.paragraph_count(book)} paragraphs")

      {:ok, book}
    end
  end

  @doc """
  Loads rules from a JSON config file.
  """
  def load_rules(profile) do
    path = Path.join([@rules_dir, "#{profile}.json"])

    case File.read(path) do
      {:ok, content} ->
        {:ok, Jason.decode!(content)}

      {:error, :enoent} ->
        Logger.warning("Rule profile '#{profile}' not found at #{path}, using defaults")
        {:ok, default_rules()}

      {:error, reason} ->
        {:error, {:rules_load_failed, reason}}
    end
  end

  defp parse_chapters(text, rules) do
    chapter_patterns = Map.get(rules, "chapter_patterns", ["^#+\\s+.+"])

    text
    |> ChapterRules.split_chapters(chapter_patterns)
    |> Enum.with_index(1)
    |> Enum.map(fn {{title, content}, idx} ->
      paragraphs =
        content
        |> ParagraphRules.split_paragraphs(rules)
        |> SpeakerRules.detect_speakers(rules)

      Chapter.new(%{
        n: idx,
        title: title || "Chapter #{idx}",
        paragraphs: paragraphs
      })
    end)
  end

  defp default_rules do
    %{
      "chapter_patterns" => [
        "^#+\\s+Chapter\\s+\\d+",
        "^#+\\s+CHAPTER\\s+[IVXLCDM]+",
        "^#+\\s+CHAPITRE\\s+[IVXLCDM]+"
      ],
      "paragraph_separator" => "\\n\\n",
      "strip_patterns" => [
        "^\\d{1,3}$"
      ],
      "speaker_patterns" => %{
        "dialogue_dash" => "^[—–]\\s*",
        "known_speakers" => []
      },
      "default_speaker" => "Narrator"
    }
  end
end
