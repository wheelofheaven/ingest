defmodule Ingest.Schema.Section do
  @moduledoc """
  Represents a section (subchapter) within a chapter.

  Sections are an optional grouping layer between chapters and paragraphs.
  When a chapter has sections, paragraphs are nested under them.
  Paragraph numbering remains sequential across the whole chapter.

  Fields:
  - `n` — Section number within the chapter (1-indexed)
  - `title` — Section title
  - `i18n` — Map of language code => translated title
  - `paragraphs` — List of `Paragraph` structs
  """

  alias Ingest.Schema.Paragraph

  @type t :: %__MODULE__{
          n: pos_integer(),
          title: String.t(),
          i18n: %{String.t() => String.t()},
          paragraphs: [Paragraph.t()]
        }

  @derive Jason.Encoder
  defstruct [:n, :title, i18n: %{}, paragraphs: []]

  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  def init_i18n(%__MODULE__{} = section, languages, primary_lang) do
    i18n =
      languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Map.new(&{&1, Map.get(section.i18n, &1, "")})

    paragraphs =
      Enum.map(section.paragraphs, &Paragraph.init_i18n(&1, languages, primary_lang))

    %{section | i18n: i18n, paragraphs: paragraphs}
  end

  def paragraph_count(%__MODULE__{paragraphs: paragraphs}), do: length(paragraphs)

  def to_json(%__MODULE__{} = s) do
    %{
      "n" => s.n,
      "title" => s.title,
      "i18n" => s.i18n,
      "paragraphs" => Enum.map(s.paragraphs, &Paragraph.to_json/1)
    }
  end
end
