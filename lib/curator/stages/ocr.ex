defmodule Curator.Stages.OCR do
  @moduledoc """
  Stage 1: OCR extraction.

  Sends PDF to GLM-OCR and saves raw text to `_work/{slug}/ocr.md`.
  """

  alias Curator.OCR
  alias Curator.Stages.WorkDir

  require Logger

  @artifact "ocr.md"

  @doc """
  Extracts text from a PDF and persists the result.

  ## Parameters
  - `pdf_path` — Path to the PDF file
  - `slug` — Book slug for work directory
  - `opts` — Options passed to OCR client

  ## Returns
  - `{:ok, %{text: text, path: artifact_path}}` on success
  - `{:error, reason}` on failure
  """
  def run(pdf_path, slug, opts \\ []) do
    Logger.info("[OCR] Starting extraction for #{Path.basename(pdf_path)}")

    case OCR.Client.extract(pdf_path, opts) do
      {:ok, text} ->
        {:ok, artifact_path} = WorkDir.write_artifact(slug, @artifact, text)
        Logger.info("[OCR] Saved #{byte_size(text)} bytes to #{artifact_path}")
        {:ok, %{text: text, path: artifact_path}}

      {:error, reason} ->
        Logger.error("[OCR] Extraction failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Loads previously extracted OCR text from the work directory.
  """
  def load(slug) do
    case WorkDir.read_artifact(slug, @artifact) do
      {:ok, text} -> {:ok, text}
      {:error, :not_found} -> {:error, {:artifact_not_found, @artifact}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns true if OCR output already exists for this slug.
  """
  def done?(slug), do: WorkDir.artifact_exists?(slug, @artifact)
end
