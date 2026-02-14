defmodule Curator.Stages.WorkDir do
  @moduledoc """
  Manages the work directory for intermediate pipeline artifacts.

  Configured via `DATA_WORK_PATH` env var (default: `../curator-work`).
  Each slug gets a subdirectory with:
  - `ocr.md`     — Raw OCR output (markdown/text)
  - `book.json`  — Structured book after normalization
  - `book_translated.json` — Book with i18n slots filled
  """

  @doc """
  Returns the configured work directory root path.
  """
  def root do
    Application.get_env(:curator, :data_work_path, "../curator-work")
    |> Path.expand()
  end

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
  def path(slug), do: Path.join(root(), slug)

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

  @doc """
  Lists all slugs that have a work directory.
  """
  def list_slugs do
    r = root()

    case File.ls(r) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&File.dir?(Path.join(r, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
