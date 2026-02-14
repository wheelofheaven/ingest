defmodule PdfPipeline.Stages.Translate do
  @moduledoc """
  Stage 3: Translation.

  Takes a normalized book and translates into target languages,
  saving the result as `_work/{slug}/book_translated.json`.
  """

  alias PdfPipeline.Schema.Book
  alias PdfPipeline.Stages.{Normalize, WorkDir}
  alias PdfPipeline.Translator

  require Logger

  @artifact "book_translated.json"

  @doc """
  Translates a book into target languages and persists the result.

  ## Parameters
  - `slug` — Book slug (loads normalized book from work dir)
  - `opts` — Options:
    - `:langs` — Target languages (default: configured default_languages)
    - `:preserve_terms` — Additional terms to keep untranslated
    - `:book` — Provide book directly instead of loading from work dir

  ## Returns
  - `{:ok, %{book: book, path: artifact_path}}` on success
  - `{:error, reason}` on failure
  """
  def run(slug, opts \\ []) do
    langs = Keyword.get(opts, :langs,
      Application.get_env(:pdf_pipeline, :default_languages, ~w(en fr de es ru ja zh)))

    with {:ok, book} <- load_book(slug, opts),
         {:ok, translated} <- Translator.translate(book, langs, opts) do
      # Persist as JSON
      translated_with_i18n = Book.init_i18n(translated, langs)
      json = Book.to_json(translated_with_i18n)
      encoded = Jason.encode!(json, pretty: true)
      {:ok, artifact_path} = WorkDir.write_artifact(slug, @artifact, encoded)

      Logger.info("[Translate] Saved translated book to #{artifact_path}")
      {:ok, %{book: translated_with_i18n, path: artifact_path}}
    end
  end

  @doc """
  Loads previously translated book from the work directory.
  """
  def load(slug) do
    case WorkDir.read_artifact(slug, @artifact) do
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, :not_found} -> {:error, {:artifact_not_found, @artifact}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns true if translated output already exists for this slug.
  """
  def done?(slug), do: WorkDir.artifact_exists?(slug, @artifact)

  # Private

  defp load_book(slug, opts) do
    case Keyword.get(opts, :book) do
      nil -> Normalize.load_book(slug)
      book -> {:ok, book}
    end
  end
end
