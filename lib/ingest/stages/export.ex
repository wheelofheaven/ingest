defmodule Ingest.Stages.Export do
  @moduledoc """
  Stage 4: Export to data-library.

  Takes the final book (translated or not) and writes it to
  the data-library directory in the correct format.
  """

  alias Ingest.Export.DataLibrary
  alias Ingest.Stages.{Normalize, Translate}

  require Logger

  @doc """
  Exports a book to the data-library directory.

  Prefers the translated version if available, falls back to normalized.

  ## Parameters
  - `slug` — Book slug
  - `opts` — Options:
    - `:output_dir` — Output directory (default: configured data_library_path)
    - `:book` — Provide book directly

  ## Returns
  - `{:ok, path}` — Path to the written file(s)
  - `{:error, reason}` — Error
  """
  def run(slug, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir)

    with {:ok, book} <- load_book(slug, opts) do
      Logger.info("[Export] Exporting '#{slug}' to data-library")
      DataLibrary.export(book, output_dir)
    end
  end

  defp load_book(slug, opts) do
    case Keyword.get(opts, :book) do
      nil ->
        # Prefer translated, fall back to normalized
        case Translate.done?(slug) do
          true ->
            Logger.info("[Export] Loading translated book")
            Normalize.load_book(slug) |> load_translations(slug)

          false ->
            Logger.info("[Export] No translated version, loading normalized book")
            Normalize.load_book(slug)
        end

      book ->
        {:ok, book}
    end
  end

  defp load_translations({:ok, book}, slug) do
    case Translate.load(slug) do
      {:ok, translated_json} ->
        {:ok, apply_translations_to_book(book, translated_json)}

      {:error, _} ->
        {:ok, book}
    end
  end

  defp load_translations(error, _slug), do: error

  defp apply_translations_to_book(book, translated_json) do
    alias Ingest.Schema.Chapter

    translated_chapters = translated_json["chapters"] || []

    chapters =
      Enum.zip(book.chapters, translated_chapters)
      |> Enum.map(fn {chapter, t_ch} ->
        i18n = t_ch["i18n"] || %{}

        if Chapter.has_sections?(chapter) do
          t_sections = t_ch["sections"] || []

          sections =
            Enum.zip(chapter.sections, t_sections)
            |> Enum.map(fn {section, t_s} ->
              s_i18n = t_s["i18n"] || %{}

              paragraphs =
                Enum.zip(section.paragraphs, t_s["paragraphs"] || [])
                |> Enum.map(fn {para, t_p} ->
                  %{para | i18n: t_p["i18n"] || para.i18n}
                end)

              %{section | i18n: s_i18n, paragraphs: paragraphs}
            end)

          %{chapter | i18n: i18n, sections: sections}
        else
          paragraphs =
            Enum.zip(chapter.paragraphs, t_ch["paragraphs"] || [])
            |> Enum.map(fn {para, t_p} ->
              %{para | i18n: t_p["i18n"] || para.i18n}
            end)

          %{chapter | i18n: i18n, paragraphs: paragraphs}
        end
      end)

    %{book | chapters: chapters}
  end
end
