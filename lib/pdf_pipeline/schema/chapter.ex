defmodule PdfPipeline.Schema.Chapter do
  @moduledoc """
  Represents a chapter in a book, matching data-library format.

  Fields:
  - `n` — Chapter number (1-indexed)
  - `title` — Chapter title in primary language
  - `i18n` — Map of language code => translated title
  - `paragraphs` — List of `Paragraph` structs
  - `ref_id` — Canonical reference (e.g., "TBWTT-1")
  """

  alias PdfPipeline.Schema.Paragraph

  @type t :: %__MODULE__{
          n: pos_integer(),
          title: String.t(),
          i18n: %{String.t() => String.t()},
          paragraphs: [Paragraph.t()],
          ref_id: String.t()
        }

  @derive Jason.Encoder
  defstruct [:n, :title, :ref_id, i18n: %{}, paragraphs: []]

  @doc """
  Creates a new chapter with initialized i18n slots.
  """
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Initializes empty i18n slots for the given languages, excluding primary.
  Also initializes i18n for all child paragraphs.
  """
  def init_i18n(%__MODULE__{} = chapter, languages, primary_lang) do
    i18n =
      languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Map.new(&{&1, Map.get(chapter.i18n, &1, "")})

    paragraphs =
      Enum.map(chapter.paragraphs, &Paragraph.init_i18n(&1, languages, primary_lang))

    %{chapter | i18n: i18n, paragraphs: paragraphs}
  end

  @doc """
  Returns the total number of paragraphs in this chapter.
  """
  def paragraph_count(%__MODULE__{paragraphs: paragraphs}), do: length(paragraphs)

  @doc """
  Serializes to data-library JSON format.
  """
  def to_json(%__MODULE__{} = c) do
    %{
      "n" => c.n,
      "title" => c.title,
      "i18n" => c.i18n,
      "paragraphs" => Enum.map(c.paragraphs, &Paragraph.to_json/1),
      "refId" => c.ref_id
    }
  end
end
