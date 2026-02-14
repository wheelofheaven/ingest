defmodule Curator.Sources do
  @moduledoc """
  Discovers PDF source files and their sidecar metadata
  from the configured source directory.
  """

  @doc """
  Returns the configured source directory path.
  """
  def source_dir do
    Application.get_env(:curator, :data_sources_path, "../data-sources")
    |> Path.expand()
  end

  @doc """
  Scans the source directory for PDF files and returns a list of source entries.

  Each entry is a map with:
  - `:path` — Absolute path to the PDF
  - `:relative` — Path relative to source dir
  - `:filename` — Just the filename
  - `:size` — File size in bytes
  - `:sidecar` — Parsed sidecar JSON (or nil)
  - `:books` — List of book entries (from sidecar or synthesized)
  """
  def list_sources do
    dir = source_dir()

    if File.dir?(dir) do
      dir
      |> scan_pdfs()
      |> Enum.map(&build_entry(dir, &1))
      |> Enum.sort_by(& &1.filename)
    else
      []
    end
  end

  @doc """
  Loads sidecar metadata for a PDF path.
  Returns the parsed JSON map or an empty map.
  """
  def load_sidecar(pdf_path) do
    json_path = String.replace_suffix(pdf_path, ".pdf", ".json")

    case File.read(json_path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> nil
    end
  end

  @doc """
  Extracts book entries from a sidecar.
  For anthologies, returns the `contains` list.
  For single books, wraps the sidecar itself.
  """
  def books_from_sidecar(nil), do: []

  def books_from_sidecar(sidecar) do
    case sidecar["type"] do
      "anthology" ->
        (sidecar["contains"] || [])
        |> Enum.map(fn book ->
          book
          |> Map.put("language", sidecar["language"])
          |> Map.put("tradition", sidecar["tradition"])
          |> Map.put("collection", sidecar["collection"])
          |> Map.put("rules", sidecar["rules"])
          |> Map.put("author", sidecar["author"])
        end)

      _ ->
        [sidecar]
    end
  end

  # Private

  defp scan_pdfs(dir) do
    Path.wildcard(Path.join([dir, "**", "*.pdf"]))
  end

  defp build_entry(base_dir, pdf_path) do
    sidecar = load_sidecar(pdf_path)
    stat = File.stat!(pdf_path)

    %{
      path: pdf_path,
      relative: Path.relative_to(pdf_path, base_dir),
      filename: Path.basename(pdf_path),
      size: stat.size,
      sidecar: sidecar,
      books: books_from_sidecar(sidecar)
    }
  end
end
