defmodule Curator.Schema.Chapter do
  @moduledoc """
  Represents a chapter in a book, matching data-library format.

  Fields:
  - `n` — Chapter number (1-indexed)
  - `title` — Chapter title in primary language
  - `i18n` — Map of language code => translated title
  - `paragraphs` — List of `Paragraph` structs (when no sections)
  - `sections` — Optional list of `Section` structs (subchapters)
  - `ref_id` — Canonical reference (e.g., "TBWTT-1")

  When sections are present, paragraphs live inside sections.
  When no sections, paragraphs are directly under the chapter.
  """

  alias Curator.Schema.{Paragraph, Section}

  @type t :: %__MODULE__{
          n: pos_integer(),
          title: String.t(),
          i18n: %{String.t() => String.t()},
          paragraphs: [Paragraph.t()],
          sections: [Section.t()],
          ref_id: String.t()
        }

  @derive Jason.Encoder
  defstruct [:n, :title, :ref_id, i18n: %{}, paragraphs: [], sections: []]

  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  def init_i18n(%__MODULE__{} = chapter, languages, primary_lang) do
    i18n =
      languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Map.new(&{&1, Map.get(chapter.i18n, &1, "")})

    paragraphs =
      Enum.map(chapter.paragraphs, &Paragraph.init_i18n(&1, languages, primary_lang))

    sections =
      Enum.map(chapter.sections, &Section.init_i18n(&1, languages, primary_lang))

    %{chapter | i18n: i18n, paragraphs: paragraphs, sections: sections}
  end

  @doc """
  Returns all paragraphs in this chapter, whether directly under the chapter
  or nested inside sections.
  """
  def all_paragraphs(%__MODULE__{sections: sections, paragraphs: paragraphs}) do
    if sections != [] do
      Enum.flat_map(sections, & &1.paragraphs)
    else
      paragraphs
    end
  end

  @doc """
  Returns the total number of paragraphs in this chapter.
  """
  def paragraph_count(%__MODULE__{} = chapter) do
    length(all_paragraphs(chapter))
  end

  @doc """
  Returns whether this chapter uses sections.
  """
  def has_sections?(%__MODULE__{sections: sections}), do: sections != []

  def to_json(%__MODULE__{} = c) do
    base = %{
      "n" => c.n,
      "title" => c.title,
      "i18n" => c.i18n,
      "refId" => c.ref_id
    }

    if c.sections != [] do
      Map.put(base, "sections", Enum.map(c.sections, &Section.to_json/1))
    else
      Map.put(base, "paragraphs", Enum.map(c.paragraphs, &Paragraph.to_json/1))
    end
  end
end
