defmodule Ingest.Schema.Book do
  @moduledoc """
  Represents a complete book, matching data-library JSON format.

  Top-level fields mirror the data-library schema:
  - `slug` — kebab-case identifier
  - `code` — Short book code (e.g., "TBWTT")
  - `primary_lang` — ISO 639-1 code of original language
  - `titles` — Map of language code => title
  - `publication_year` — Year of publication or nil
  - `chapters` — List of `Chapter` structs
  - `revision` — Version number
  - `updated` — ISO 8601 timestamp
  """

  alias Ingest.Schema.Chapter

  @type t :: %__MODULE__{
          slug: String.t(),
          code: String.t(),
          primary_lang: String.t(),
          titles: %{String.t() => String.t()},
          publication_year: integer() | nil,
          chapters: [Chapter.t()],
          revision: integer(),
          updated: String.t()
        }

  @derive Jason.Encoder
  defstruct [
    :slug,
    :code,
    :primary_lang,
    :publication_year,
    titles: %{},
    chapters: [],
    revision: 1,
    updated: nil
  ]

  @doc """
  Creates a new book struct.
  """
  def new(attrs) do
    book = struct!(__MODULE__, attrs)
    %{book | updated: book.updated || DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  @doc """
  Assigns ref_id values to all chapters and paragraphs based on the book code.
  """
  def assign_ref_ids(%__MODULE__{code: code} = book) do
    chapters =
      book.chapters
      |> Enum.with_index(1)
      |> Enum.map(fn {chapter, ch_idx} ->
        chapter = %{chapter | n: ch_idx, ref_id: "#{code}-#{ch_idx}"}

        if Chapter.has_sections?(chapter) do
          {sections, _counter} =
            chapter.sections
            |> Enum.with_index(1)
            |> Enum.map_reduce(1, fn {section, s_idx}, p_counter ->
              section = %{section | n: s_idx}

              {paragraphs, next_counter} =
                section.paragraphs
                |> Enum.map_reduce(p_counter, fn para, p_idx ->
                  {%{para | n: p_idx, ref_id: "#{code}-#{ch_idx}:#{p_idx}"}, p_idx + 1}
                end)

              {%{section | paragraphs: paragraphs}, next_counter}
            end)

          %{chapter | sections: sections, paragraphs: []}
        else
          paragraphs =
            chapter.paragraphs
            |> Enum.with_index(1)
            |> Enum.map(fn {para, p_idx} ->
              %{para | n: p_idx, ref_id: "#{code}-#{ch_idx}:#{p_idx}"}
            end)

          %{chapter | paragraphs: paragraphs}
        end
      end)

    %{book | chapters: chapters}
  end

  @doc """
  Initializes empty i18n slots for all languages on all chapters and paragraphs.
  """
  def init_i18n(%__MODULE__{} = book, languages) do
    chapters =
      Enum.map(book.chapters, &Chapter.init_i18n(&1, languages, book.primary_lang))

    %{book | chapters: chapters}
  end

  @doc """
  Returns total paragraph count across all chapters.
  """
  def paragraph_count(%__MODULE__{chapters: chapters}) do
    Enum.sum(Enum.map(chapters, &Chapter.paragraph_count/1))
  end

  @doc """
  Returns total chapter count.
  """
  def chapter_count(%__MODULE__{chapters: chapters}), do: length(chapters)

  @doc """
  Serializes to data-library JSON format.
  """
  def to_json(%__MODULE__{} = b) do
    %{
      "slug" => b.slug,
      "code" => b.code,
      "primaryLang" => b.primary_lang,
      "titles" => b.titles,
      "publicationYear" => b.publication_year,
      "schema" => schema_list(b),
      "revision" => b.revision,
      "updated" => b.updated,
      "chapters" => Enum.map(b.chapters, &Chapter.to_json/1),
      "refId" => b.code,
      "paragraphCount" => paragraph_count(b),
      "chapterCount" => chapter_count(b)
    }
  end

  defp schema_list(%__MODULE__{chapters: chapters}) do
    has_sections = Enum.any?(chapters, &Chapter.has_sections?/1)

    if has_sections do
      ["book", "chapters", "sections", "paragraphs"]
    else
      ["book", "chapters", "paragraphs"]
    end
  end
end
