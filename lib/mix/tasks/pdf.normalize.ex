defmodule Mix.Tasks.Pdf.Normalize do
  @moduledoc """
  Normalizes OCR text into structured book JSON (Stage 2).

  Reads from `_work/{slug}/ocr.md` and writes `_work/{slug}/book.json`.

  ## Usage

      mix pdf.normalize --slug my-book --code MYBOOK --lang fr --rules raelian

  If a sidecar JSON exists for the original PDF, metadata is loaded automatically:

      mix pdf.normalize --slug my-book

  ## Options

  - `--slug` — Book slug (required)
  - `--code` — Book code, e.g. "TBWTT" (required unless in sidecar)
  - `--lang` — Primary language (required unless in sidecar)
  - `--rules` — Rule profile name (default: "default")
  - `--refine` — Run LLM refinement on low-confidence paragraphs
  - `--force` — Re-run even if output exists
  - `--title` — Book title in primary language
  """

  use Mix.Task

  @shortdoc "Normalize OCR text into structured book JSON"

  @switches [
    slug: :string,
    code: :string,
    lang: :string,
    rules: :string,
    refine: :boolean,
    force: :boolean,
    title: :string,
    year: :integer,
    sidecar: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} = OptionParser.parse(args, strict: @switches)

    slug = opts[:slug] || Mix.raise("--slug is required")

    Mix.Task.run("app.start")

    unless PdfPipeline.Stages.OCR.done?(slug) do
      Mix.raise("No OCR output found for '#{slug}'. Run `mix pdf.ocr` first.")
    end

    if PdfPipeline.Stages.Normalize.done?(slug) && !opts[:force] do
      Mix.shell().info("Normalized output already exists for '#{slug}'. Use --force to re-run.")
      Mix.shell().info("  Path: #{PdfPipeline.Stages.WorkDir.artifact(slug, "book.json")}")
      return_existing(slug)
    else
      sidecar = load_sidecar_for_slug(slug, opts[:sidecar])

      code = opts[:code] || sidecar["code"] || Mix.raise("--code is required (or provide --sidecar)")
      lang = opts[:lang] || sidecar["language"] || Mix.raise("--lang is required (or provide --sidecar)")

      metadata = %{
        slug: slug,
        code: String.upcase(code),
        primary_lang: lang,
        title: opts[:title] || sidecar["title"],
        publication_year: opts[:year] || sidecar["year"]
      }

      normalize_opts = [
        rules: opts[:rules] || sidecar["rules"] || "default",
        refine: opts[:refine] || false
      ]

      Mix.shell().info("Starting normalization...")
      Mix.shell().info("  Slug: #{slug}")
      Mix.shell().info("  Code: #{metadata.code}")
      Mix.shell().info("  Language: #{lang}")
      Mix.shell().info("  Rules: #{normalize_opts[:rules]}")
      Mix.shell().info("  LLM Refine: #{normalize_opts[:refine]}")
      Mix.shell().info("")

      case PdfPipeline.Stages.Normalize.run(slug, metadata, normalize_opts) do
        {:ok, result} ->
          book = result.book
          stats = PdfPipeline.Refiner.Strategy.refinement_stats(book)

          Mix.shell().info("Normalization complete!")
          Mix.shell().info("  Output: #{result.path}")
          Mix.shell().info("  Chapters: #{PdfPipeline.Schema.Book.chapter_count(book)}")
          Mix.shell().info("  Paragraphs: #{stats.total}")
          Mix.shell().info("  Confidence: #{stats.percentage_clear}% clear")
          Mix.shell().info("")
          Mix.shell().info("Next step: mix pdf.translate --slug #{slug}")

        {:error, reason} ->
          Mix.raise("Normalization failed: #{inspect(reason)}")
      end
    end
  end

  defp return_existing(slug) do
    case PdfPipeline.Stages.Normalize.load(slug) do
      {:ok, json} ->
        chapters = length(json["chapters"] || [])
        paragraphs = json["paragraphCount"] || 0
        Mix.shell().info("  Chapters: #{chapters}, Paragraphs: #{paragraphs}")

      _ ->
        :ok
    end
  end

  defp load_sidecar_for_slug(_slug, path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> %{}
    end
  end

  defp load_sidecar_for_slug(_slug, nil), do: %{}
end
