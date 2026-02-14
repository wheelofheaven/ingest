defmodule PdfPipeline.Export.SplitFile do
  @moduledoc """
  Writes a book as multiple files: _meta.json + chapter-N.json per chapter.

  Used for larger books (over 100KB serialized).
  Output directory: `{output_dir}/{slug}/`
  """

  alias PdfPipeline.Schema.{Book, Chapter}

  require Logger

  @doc """
  Writes the book as split files in a subdirectory.

  Returns `{:ok, dir_path}` on success.
  """
  def write(%Book{} = book, output_dir) do
    book_dir = Path.join(output_dir, book.slug)
    File.mkdir_p!(book_dir)

    # Write _meta.json
    meta = build_meta(book)
    meta_path = Path.join(book_dir, "_meta.json")
    File.write!(meta_path, Jason.encode!(meta, pretty: true))

    # Write individual chapter files
    Enum.each(book.chapters, fn chapter ->
      chapter_json = build_chapter_json(chapter, book)
      filename = "chapter-#{chapter.n}.json"
      chapter_path = Path.join(book_dir, filename)
      File.write!(chapter_path, Jason.encode!(chapter_json, pretty: true))
    end)

    Logger.info("Wrote split-file book to #{book_dir}/ (#{Book.chapter_count(book)} chapter files)")

    {:ok, book_dir}
  end

  defp build_meta(%Book{} = book) do
    %{
      "slug" => book.slug,
      "code" => book.code,
      "titles" => book.titles,
      "primaryLang" => book.primary_lang,
      "publicationYear" => book.publication_year,
      "schema" => ["book", "chapters", "paragraphs"],
      "revision" => book.revision,
      "updated" => book.updated,
      "refId" => book.code,
      "chapterCount" => Book.chapter_count(book),
      "paragraphCount" => Book.paragraph_count(book),
      "chapterFiles" =>
        Enum.map(book.chapters, fn ch ->
          %{
            "n" => ch.n,
            "file" => "chapter-#{ch.n}.json",
            "title" => ch.title,
            "paragraphs" => Chapter.paragraph_count(ch)
          }
        end)
    }
  end

  defp build_chapter_json(%Chapter{} = chapter, %Book{} = book) do
    %{
      "n" => chapter.n,
      "bookSlug" => book.slug,
      "bookCode" => book.code,
      "refId" => chapter.ref_id,
      "title" => chapter.title,
      "i18n" => chapter.i18n,
      "paragraphs" => Enum.map(chapter.paragraphs, &PdfPipeline.Schema.Paragraph.to_json/1)
    }
  end
end
