defmodule Mix.Tasks.Curator.Ocr do
  @moduledoc """
  Extracts text from a PDF using GLM-OCR (Stage 1).

  Saves raw OCR output to `_work/{slug}/ocr.md`.

  ## Usage

      mix curator.ocr path/to/book.pdf --slug my-book

  If a sidecar JSON exists alongside the PDF, the slug is loaded automatically:

      mix curator.ocr path/to/book.pdf
  """

  use Mix.Task

  @shortdoc "Extract text from a source document via GLM-OCR"

  @switches [
    slug: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    pdf_path =
      case positional do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix curator.ocr <pdf_path> [--slug <slug>]")
      end

    unless File.exists?(pdf_path) do
      Mix.raise("PDF file not found: #{pdf_path}")
    end

    sidecar = load_sidecar(pdf_path)
    slug = opts[:slug] || sidecar["slug"] || Mix.raise("--slug is required (or provide a sidecar JSON)")

    Mix.Task.run("app.start")

    if Curator.Stages.OCR.done?(slug) && !opts[:force] do
      Mix.shell().info("OCR output already exists for '#{slug}'. Use --force to re-extract.")
      Mix.shell().info("  Path: #{Curator.Stages.WorkDir.artifact(slug, "ocr.md")}")
      return_existing(slug)
    else
      Mix.shell().info("Starting OCR extraction...")
      Mix.shell().info("  PDF: #{pdf_path}")
      Mix.shell().info("  Slug: #{slug}")
      Mix.shell().info("")

      case Curator.Stages.OCR.run(pdf_path, slug) do
        {:ok, result} ->
          Mix.shell().info("OCR extraction complete!")
          Mix.shell().info("  Output: #{result.path}")
          Mix.shell().info("  Size: #{byte_size(result.text)} bytes")
          Mix.shell().info("")
          Mix.shell().info("Next step: mix curator.normalize --slug #{slug}")

        {:error, reason} ->
          Mix.raise("OCR extraction failed: #{inspect(reason)}")
      end
    end
  end

  defp return_existing(slug) do
    case Curator.Stages.OCR.load(slug) do
      {:ok, text} ->
        Mix.shell().info("  Size: #{byte_size(text)} bytes")

      _ ->
        :ok
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
