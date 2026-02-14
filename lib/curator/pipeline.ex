defmodule Curator.Pipeline do
  @moduledoc """
  Main pipeline orchestrator.

  Coordinates the flow through discrete stages, each with persisted artifacts:

    1. OCR       → `{slug}/ocr.md`
    2. Normalize → `{slug}/book.json`
    3. Translate → `{slug}/book_translated.json`
    4. Export    → data-library directory

  Each stage can be run independently via mix tasks:

    mix curator.ocr       — Extract text from source document
    mix curator.normalize — Parse into structured JSON
    mix curator.translate — Translate into target languages
    mix curator.export    — Write to data-library format

  Or run the full pipeline at once via `mix curator.run`.
  """

  alias Curator.Stages
  alias Curator.Store.Job

  require Logger

  @doc """
  Runs the full pipeline for a PDF file.

  Stages that have already completed (artifacts exist in `_work/{slug}/`)
  are automatically skipped unless `:force` is passed.

  ## Options
  - `:rules` — Rule profile name (default: "default")
  - `:refine` — Whether to run LLM refinement (default: false)
  - `:translate` — Whether to run translation (default: false)
  - `:langs` — Target languages for translation
  - `:output_dir` — Output directory for export
  - `:force` — Re-run all stages even if artifacts exist (default: false)
  - `:job_id` — Optional existing job ID to update
  """
  def run(pdf_path, metadata, opts \\ []) do
    slug = metadata[:slug] || metadata.slug

    # Create or use existing job
    job_id =
      case Keyword.get(opts, :job_id) do
        nil ->
          {:ok, id} = Job.create(pdf_path, metadata)
          id

        id ->
          id
      end

    force = Keyword.get(opts, :force, false)

    with {:ok, _} <- Job.update(job_id, %{status: :ocr}),
         {:ok, ocr_result} <- maybe_ocr(pdf_path, slug, force, opts),
         {:ok, _} <- Job.update(job_id, %{status: :parsing, ocr_text: ocr_result.text}),
         {:ok, norm_result} <- maybe_normalize(slug, metadata, force, opts),
         {:ok, book} <- maybe_translate(slug, norm_result.book, opts, job_id),
         {:ok, _} <- Job.update(job_id, %{status: :exporting, book: book}),
         {:ok, output_path} <- Stages.Export.run(slug, export_opts(opts)),
         {:ok, _} <- Job.update(job_id, %{
           status: :complete,
           output_path: output_path,
           completed_at: DateTime.utc_now()
         }) do
      {:ok, %{job_id: job_id, output_path: output_path, book: book}}
    else
      {:error, reason} ->
        Job.update(job_id, %{status: :error, errors: [inspect(reason)]})
        {:error, reason}
    end
  end

  @doc """
  Returns the status of each stage for a given slug.
  """
  def status(slug) do
    %{
      ocr: Stages.OCR.done?(slug),
      normalize: Stages.Normalize.done?(slug),
      translate: Stages.Translate.done?(slug),
      artifacts: Stages.WorkDir.list_artifacts(slug)
    }
  end

  defp maybe_ocr(pdf_path, slug, force, opts) do
    if !force && Stages.OCR.done?(slug) do
      Logger.info("[Pipeline] OCR already done for #{slug}, loading from cache")

      case Stages.OCR.load(slug) do
        {:ok, text} ->
          path = Stages.WorkDir.artifact(slug, "ocr.md")
          {:ok, %{text: text, path: path}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Stages.OCR.run(pdf_path, slug, opts)
    end
  end

  defp maybe_normalize(slug, metadata, force, opts) do
    if !force && Stages.Normalize.done?(slug) do
      Logger.info("[Pipeline] Normalize already done for #{slug}, loading from cache")

      case Stages.Normalize.load_book(slug) do
        {:ok, book} ->
          path = Stages.WorkDir.artifact(slug, "book.json")
          {:ok, %{book: book, path: path}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Stages.Normalize.run(slug, metadata, normalize_opts(opts))
    end
  end

  defp maybe_translate(slug, book, opts, job_id) do
    if Keyword.get(opts, :translate, false) do
      Job.update(job_id, %{status: :translating})
      langs = Keyword.get(opts, :langs)
      translate_opts = if langs, do: [langs: langs], else: []

      case Stages.Translate.run(slug, [book: book] ++ translate_opts) do
        {:ok, result} -> {:ok, result.book}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, book}
    end
  end

  defp normalize_opts(opts) do
    [
      rules: Keyword.get(opts, :rules, "default"),
      refine: Keyword.get(opts, :refine, false)
    ]
  end

  defp export_opts(opts) do
    case Keyword.get(opts, :output_dir) do
      nil -> []
      dir -> [output_dir: dir]
    end
  end
end
