defmodule Mix.Tasks.Curator.Run do
  @moduledoc """
  Runs the full pipeline: OCR → Normalize → (optional Translate) → Export.

  This is a convenience task that runs all stages sequentially.
  For more control, use the individual stage tasks:

    mix curator.ocr        — Extract text from PDF
    mix curator.normalize   — Parse into structured JSON
    mix curator.translate   — Translate into target languages
    mix curator.export      — Write to data-library format

  ## Usage

  If a sidecar JSON file exists alongside the PDF (same name, `.json` extension),
  metadata is loaded automatically:

      mix curator.run path/to/book.pdf

  Otherwise, provide metadata via CLI flags:

      mix curator.run path/to/book.pdf \\
        --slug the-book-which-tells-the-truth \\
        --code TBWTT \\
        --lang fr \\
        --rules raelian \\
        --output ../data-library

  CLI flags override sidecar JSON values when both are present.

  ## Options

  - `--slug` — Book slug (kebab-case identifier)
  - `--code` — Book code (uppercase, e.g., "TBWTT")
  - `--lang` — Primary language (ISO 639-1 code)
  - `--rules` — Rule profile name (default: from sidecar or "default")
  - `--output` — Output directory (default: configured DATA_LIBRARY_PATH)
  - `--title` — Book title in primary language
  - `--year` — Publication year
  - `--no-refine` — Skip LLM refinement stage
  - `--translate` — Run translation stage
  - `--langs` — Comma-separated target languages for translation
  - `--tradition` — Tradition identifier
  - `--collection` — Collection identifier
  """

  use Mix.Task

  @shortdoc "Run full source document curation pipeline (OCR → Normalize → Export)"

  @switches [
    slug: :string,
    code: :string,
    lang: :string,
    rules: :string,
    output: :string,
    title: :string,
    year: :integer,
    tradition: :string,
    collection: :string,
    no_refine: :boolean,
    translate: :boolean,
    langs: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    pdf_path =
      case positional do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix curator.run <pdf_path> [options]")
      end

    unless File.exists?(pdf_path) do
      Mix.raise("PDF file not found: #{pdf_path}")
    end

    sidecar = load_sidecar(pdf_path)

    slug = opts[:slug] || sidecar["slug"] || Mix.raise("--slug is required (or provide a sidecar JSON)")
    code = opts[:code] || sidecar["code"] || Mix.raise("--code is required (or provide a sidecar JSON)")
    lang = opts[:lang] || sidecar["language"] || Mix.raise("--lang is required (or provide a sidecar JSON)")

    metadata = %{
      slug: slug,
      code: String.upcase(code),
      primary_lang: lang,
      title: opts[:title] || sidecar["title"],
      publication_year: opts[:year] || sidecar["year"],
      tradition: opts[:tradition] || sidecar["tradition"],
      collection: opts[:collection] || sidecar["collection"]
    }

    langs =
      case opts[:langs] do
        nil -> nil
        str -> String.split(str, ",", trim: true)
      end

    pipeline_opts =
      [
        rules: opts[:rules] || sidecar["rules"] || "default",
        output_dir: opts[:output],
        refine: !opts[:no_refine],
        translate: opts[:translate] || false
      ] ++ if(langs, do: [langs: langs], else: [])

    Mix.Task.run("app.start")

    if sidecar != %{} do
      Mix.shell().info("Loaded metadata from sidecar JSON")
    end

    Mix.shell().info("Starting PDF curation pipeline...")
    Mix.shell().info("  PDF: #{pdf_path}")
    Mix.shell().info("  Slug: #{slug}")
    Mix.shell().info("  Code: #{metadata.code}")
    Mix.shell().info("  Language: #{lang}")
    Mix.shell().info("  Rules: #{pipeline_opts[:rules]}")
    Mix.shell().info("  Refine: #{pipeline_opts[:refine]}")
    Mix.shell().info("  Translate: #{pipeline_opts[:translate]}")
    Mix.shell().info("")

    case Curator.Pipeline.run(pdf_path, metadata, pipeline_opts) do
      {:ok, result} ->
        Mix.shell().info("Pipeline completed successfully!")
        Mix.shell().info("  Job ID: #{result.job_id}")
        Mix.shell().info("  Output: #{result.output_path}")

        book = result.book
        stats = Curator.Refiner.Strategy.refinement_stats(book)
        Mix.shell().info("  Chapters: #{Curator.Schema.Book.chapter_count(book)}")
        Mix.shell().info("  Paragraphs: #{stats.total}")
        Mix.shell().info("  Confidence: #{stats.percentage_clear}% clear")
        Mix.shell().info("")
        Mix.shell().info("Artifacts in _work/#{slug}/:")

        Curator.Stages.WorkDir.list_artifacts(slug)
        |> Enum.each(fn f -> Mix.shell().info("  - #{f}") end)

      {:error, reason} ->
        Mix.raise("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp load_sidecar(pdf_path) do
    json_path = String.replace_suffix(pdf_path, ".pdf", ".json")

    case File.read(json_path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> %{}
    end
  end
end
