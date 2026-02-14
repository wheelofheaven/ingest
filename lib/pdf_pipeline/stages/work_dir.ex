defmodule PdfPipeline.Stages.WorkDir do
  @moduledoc """
  Manages the `_work/{slug}/` directory for intermediate pipeline artifacts.

  Each stage reads from and writes to this directory:
  - `ocr.md`     — Raw OCR output (markdown/text)
  - `book.json`  — Structured book after normalization
  - `book_translated.json` — Book with i18n slots filled
  """

  @work_root "_work"

  @doc """
  Returns the work directory path for a given slug.
  Creates the directory if it doesn't exist.
  """
  def ensure(slug) do
    dir = path(slug)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Returns the work directory path for a given slug (without creating it).
  """
  def path(slug), do: Path.join(@work_root, slug)

  @doc """
  Returns the path to a specific artifact within the work directory.
  """
  def artifact(slug, name), do: Path.join(path(slug), name)

  @doc """
  Writes an artifact to the work directory.
  """
  def write_artifact(slug, name, content) do
    dir = ensure(slug)
    path = Path.join(dir, name)
    File.write!(path, content)
    {:ok, path}
  end

  @doc """
  Reads an artifact from the work directory.
  Returns `{:ok, content}` or `{:error, :not_found}`.
  """
  def read_artifact(slug, name) do
    path = artifact(slug, name)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if an artifact exists.
  """
  def artifact_exists?(slug, name) do
    File.exists?(artifact(slug, name))
  end

  @doc """
  Lists all artifacts in a work directory.
  """
  def list_artifacts(slug) do
    dir = path(slug)

    case File.ls(dir) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end
end
