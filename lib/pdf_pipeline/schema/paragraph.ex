defmodule PdfPipeline.Schema.Paragraph do
  @moduledoc """
  Represents a single paragraph in a book, matching data-library format.

  Fields:
  - `n` — Paragraph number within the chapter (1-indexed)
  - `speaker` — Speaker name (e.g., "Narrator", "Yahweh") or nil
  - `text` — Text in the primary language
  - `i18n` — Map of language code => translated text
  - `ref_id` — Canonical reference (e.g., "TBWTT-1:5")
  - `confidence` — Parsing confidence score (0.0-1.0), internal only
  """

  @type t :: %__MODULE__{
          n: pos_integer(),
          speaker: String.t() | nil,
          text: String.t(),
          i18n: %{String.t() => String.t()},
          ref_id: String.t(),
          confidence: float()
        }

  @derive Jason.Encoder
  defstruct [:n, :speaker, :text, :ref_id, i18n: %{}, confidence: 1.0]

  @doc """
  Creates a new paragraph with initialized i18n slots.
  """
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Initializes empty i18n slots for the given languages, excluding the primary language.
  """
  def init_i18n(%__MODULE__{} = paragraph, languages, primary_lang) do
    i18n =
      languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Map.new(&{&1, Map.get(paragraph.i18n, &1, "")})

    %{paragraph | i18n: i18n}
  end

  @doc """
  Serializes to data-library JSON format.
  """
  def to_json(%__MODULE__{} = p) do
    map = %{
      "n" => p.n,
      "speaker" => p.speaker,
      "text" => p.text,
      "i18n" => p.i18n,
      "refId" => p.ref_id
    }

    map
  end
end
