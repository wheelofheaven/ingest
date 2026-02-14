defmodule PdfPipeline.Stages.Normalize do
  @moduledoc """
  Stage 2: Normalization.

  Takes raw OCR text and applies rule-based parsing to produce
  a structured `%Book{}`, then saves as `_work/{slug}/book.json`.

  Optionally runs LLM refinement for low-confidence paragraphs.
  """

  alias PdfPipeline.Parser.RuleEngine
  alias PdfPipeline.Refiner.Strategy
  alias PdfPipeline.Schema.Book
  alias PdfPipeline.Stages.WorkDir

  require Logger

  @artifact "book.json"

  @doc """
  Parses OCR text into structured book JSON and persists it.

  ## Parameters
  - `slug` — Book slug (loads OCR text from work dir)
  - `metadata` — Map with `:slug`, `:code`, `:primary_lang`, etc.
  - `opts` — Options:
    - `:rules` — Rule profile name (default: "default")
    - `:refine` — Run LLM refinement (default: false)
    - `:text` — Provide text directly instead of loading from work dir

  ## Returns
  - `{:ok, %{book: book, path: artifact_path}}` on success
  - `{:error, reason}` on failure
  """
  def run(slug, metadata, opts \\ []) do
    rules_profile = Keyword.get(opts, :rules, "default")
    do_refine = Keyword.get(opts, :refine, false)

    with {:ok, text} <- load_text(slug, opts),
         {:ok, book} <- parse(text, metadata, rules_profile),
         {:ok, book} <- maybe_refine(book, do_refine) do
      json = Book.to_json(book)
      encoded = Jason.encode!(json, pretty: true)
      {:ok, artifact_path} = WorkDir.write_artifact(slug, @artifact, encoded)

      stats = Strategy.refinement_stats(book)
      Logger.info("[Normalize] #{Book.chapter_count(book)} chapters, #{stats.total} paragraphs (#{stats.percentage_clear}% clear)")
      Logger.info("[Normalize] Saved to #{artifact_path}")

      {:ok, %{book: book, path: artifact_path}}
    end
  end

  @doc """
  Loads previously normalized book from the work directory.
  Returns the raw JSON map (not a Book struct).
  """
  def load(slug) do
    case WorkDir.read_artifact(slug, @artifact) do
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, :not_found} -> {:error, {:artifact_not_found, @artifact}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads previously normalized book as a Book struct.
  """
  def load_book(slug) do
    case load(slug) do
      {:ok, json} -> {:ok, book_from_json(json)}
      error -> error
    end
  end

  @doc """
  Returns true if normalized output already exists for this slug.
  """
  def done?(slug), do: WorkDir.artifact_exists?(slug, @artifact)

  # Private

  defp load_text(slug, opts) do
    case Keyword.get(opts, :text) do
      nil ->
        case PdfPipeline.Stages.OCR.load(slug) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, {:ocr_not_found, reason}}
        end

      text ->
        {:ok, text}
    end
  end

  defp parse(text, metadata, rules_profile) do
    Logger.info("[Normalize] Parsing with rule profile: #{rules_profile}")
    RuleEngine.parse(text, metadata, rules_profile)
  end

  defp maybe_refine(book, false), do: {:ok, book}

  defp maybe_refine(book, true) do
    Logger.info("[Normalize] Running LLM refinement")
    {:ok, Strategy.refine(book)}
  end

  defp book_from_json(json) do
    chapters =
      Enum.map(json["chapters"] || [], fn ch ->
        paragraphs =
          Enum.map(ch["paragraphs"] || [], fn p ->
            %PdfPipeline.Schema.Paragraph{
              n: p["n"],
              speaker: p["speaker"],
              text: p["text"],
              i18n: p["i18n"] || %{},
              ref_id: p["refId"],
              confidence: p["confidence"] || 1.0
            }
          end)

        %PdfPipeline.Schema.Chapter{
          n: ch["n"],
          title: ch["title"],
          i18n: ch["i18n"] || %{},
          paragraphs: paragraphs,
          ref_id: ch["refId"]
        }
      end)

    Book.new(%{
      slug: json["slug"],
      code: json["code"],
      primary_lang: json["primaryLang"],
      titles: json["titles"] || %{},
      publication_year: json["publicationYear"],
      chapters: chapters,
      revision: json["revision"] || 1
    })
  end
end
