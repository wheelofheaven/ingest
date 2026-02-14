defmodule Curator.Schema.CatalogEntry do
  @moduledoc """
  Represents a book entry in the data-library catalog.json.
  """

  @type t :: %__MODULE__{
          slug: String.t(),
          code: String.t(),
          tradition: String.t(),
          collection: String.t(),
          order: integer(),
          author: String.t() | nil,
          publication_year: integer() | nil,
          original_title: String.t() | nil,
          primary_lang: String.t(),
          available_langs: [String.t()],
          complete_langs: [String.t()],
          chapters: integer(),
          paragraphs: integer(),
          tags: [String.t()],
          topics: [String.t()],
          status: String.t()
        }

  @derive Jason.Encoder
  defstruct [
    :slug,
    :code,
    :tradition,
    :collection,
    :author,
    :publication_year,
    :original_title,
    :primary_lang,
    order: 1,
    available_langs: [],
    complete_langs: [],
    chapters: 0,
    paragraphs: 0,
    tags: [],
    topics: [],
    status: "draft"
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Serializes to catalog.json book entry format.
  """
  def to_json(%__MODULE__{} = entry) do
    %{
      "slug" => entry.slug,
      "code" => entry.code,
      "tradition" => entry.tradition,
      "collection" => entry.collection,
      "order" => entry.order,
      "author" => entry.author,
      "publicationYear" => entry.publication_year,
      "originalTitle" => entry.original_title,
      "primaryLang" => entry.primary_lang,
      "availableLangs" => entry.available_langs,
      "completeLangs" => entry.complete_langs,
      "chapters" => entry.chapters,
      "paragraphs" => entry.paragraphs,
      "tags" => entry.tags,
      "topics" => entry.topics,
      "status" => entry.status,
      "hasAudio" => false,
      "hasVideo" => false
    }
  end
end
