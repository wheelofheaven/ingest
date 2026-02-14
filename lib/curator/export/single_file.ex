defmodule Curator.Export.SingleFile do
  @moduledoc """
  Writes a book as a single JSON file.

  Used for smaller books (under 100KB serialized).
  Output: `{output_dir}/{slug}.json`
  """

  alias Curator.Schema.Book

  require Logger

  @doc """
  Writes the book as a single JSON file.

  Returns `{:ok, file_path}` on success.
  """
  def write(%Book{} = book, output_dir) do
    json = Book.to_json(book)
    encoded = Jason.encode!(json, pretty: true)

    file_path = Path.join(output_dir, "#{book.slug}.json")

    File.mkdir_p!(output_dir)
    File.write!(file_path, encoded)

    Logger.info("Wrote single-file book to #{file_path} (#{byte_size(encoded)} bytes)")

    {:ok, file_path}
  end
end
