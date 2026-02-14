defmodule Curator.Ecosystem do
  @moduledoc """
  Reads data from sibling Wheel of Heaven repositories to provide
  an ecosystem overview: data-library catalog, data-content stats,
  and data-images inventory.
  """

  @content_sections ~w(wiki timeline essentials resources)
  @languages ~w(de es fr ja ko ru zh zh-Hant)

  # --- Public API ---

  @doc """
  Reads the data-library catalog.json and returns structured book data.

  Returns a map with :ok, :traditions, :collections, :books, and summary counts.
  """
  def library_catalog do
    path = catalog_path()

    case File.read(path) do
      {:ok, content} ->
        catalog = Jason.decode!(content)

        %{
          ok: true,
          traditions: catalog["traditions"] || [],
          collections: catalog["collections"] || [],
          books: catalog["books"] || [],
          book_count: length(catalog["books"] || []),
          tradition_count: length(catalog["traditions"] || []),
          collection_count: length(catalog["collections"] || [])
        }

      {:error, _} ->
        %{ok: false, traditions: [], collections: [], books: [],
          book_count: 0, tradition_count: 0, collection_count: 0}
    end
  end

  @doc """
  Scans data-content directory tree and returns section counts
  and translation coverage per language.

  Counts markdown files (excluding _index.md) in each section.
  """
  def content_stats do
    dir = content_dir()

    if File.dir?(dir) do
      base_counts = count_sections(dir)
      lang_counts = Enum.map(@languages, fn lang ->
        lang_dir = Path.join(dir, lang)
        counts = count_sections(lang_dir)
        {lang, counts}
      end)

      total_base = Enum.reduce(base_counts, 0, fn {_k, v}, acc -> acc + v end)

      %{
        ok: true,
        sections: base_counts,
        languages: Map.new(lang_counts),
        total_files: total_base,
        available_languages: @languages
      }
    else
      %{ok: false, sections: %{}, languages: %{}, total_files: 0,
        available_languages: @languages}
    end
  end

  @doc """
  Reads data-images manifest.yaml and directory counts.

  Returns raw/processed file counts plus manifest categories.
  """
  def images_stats do
    dir = images_dir()
    manifest_path = Path.join(dir, "manifest.yaml")

    manifest_data =
      case File.read(manifest_path) do
        {:ok, content} -> YamlElixir.read_from_string!(content)
        {:error, _} -> nil
      end

    raw_count = count_files(Path.join(dir, "raw"))
    processed_count = count_files(Path.join(dir, "processed"))

    if manifest_data do
      images = manifest_data["images"] || []
      categories = images
        |> Enum.map(& &1["category"])
        |> Enum.frequencies()

      %{
        ok: true,
        raw_count: raw_count,
        processed_count: processed_count,
        manifest_entries: length(images),
        categories: categories,
        global_settings: manifest_data["global_settings"] || %{}
      }
    else
      %{ok: false, raw_count: raw_count, processed_count: processed_count,
        manifest_entries: 0, categories: %{}, global_settings: %{}}
    end
  end

  # --- Path Helpers ---

  defp catalog_path do
    library_dir = Application.get_env(:curator, :data_library_path, "../data-library")
    Path.expand(library_dir) |> Path.join("catalog.json")
  end

  defp content_dir do
    Application.get_env(:curator, :data_content_path, "../data-content")
    |> Path.expand()
  end

  defp images_dir do
    Application.get_env(:curator, :data_images_path, "../data-images")
    |> Path.expand()
  end

  # --- Private Helpers ---

  defp count_sections(dir) do
    @content_sections
    |> Enum.map(fn section ->
      section_dir = Path.join(dir, section)
      count = count_markdown_files(section_dir)
      {section, count}
    end)
    |> Map.new()
  end

  defp count_markdown_files(dir) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "*.md"))
      |> Enum.reject(&(Path.basename(&1) == "_index.md"))
      |> length()
    else
      0
    end
  end

  defp count_files(dir) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "*"))
      |> Enum.count(&File.regular?/1)
    else
      0
    end
  end
end
