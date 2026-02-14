defmodule PdfPipeline.Export.DataLibrary do
  @moduledoc """
  Exports a Book struct to data-library JSON format.

  Chooses between single-file and split-file format based on size.
  """

  alias PdfPipeline.Schema.{Book, Validator}
  alias PdfPipeline.Export.{SingleFile, SplitFile}

  require Logger

  @size_threshold 100_000

  @doc """
  Exports a book to the data-library directory.

  Automatically chooses single-file or split-file format based on serialized size.
  Initializes i18n slots for all configured languages.

  ## Parameters
  - `book` — The `%Book{}` to export
  - `output_dir` — Directory to write to (defaults to configured data_library_path)

  ## Returns
  - `{:ok, path}` — Path to the written file(s)
  - `{:error, reason}` — Error
  """
  def export(%Book{} = book, output_dir \\ nil) do
    output_dir = output_dir || Application.get_env(:pdf_pipeline, :data_library_path, "../data-library")
    languages = Application.get_env(:pdf_pipeline, :default_languages, ~w(en fr de es ru ja zh))

    book =
      book
      |> Book.assign_ref_ids()
      |> Book.init_i18n(languages)

    json = Book.to_json(book)

    case Validator.validate_book(json) do
      {:ok, _} ->
        encoded = Jason.encode!(json, pretty: true)

        if byte_size(encoded) > @size_threshold do
          Logger.info("Book exceeds #{@size_threshold} bytes, using split format")
          SplitFile.write(book, output_dir)
        else
          Logger.info("Book under #{@size_threshold} bytes, using single-file format")
          SingleFile.write(book, output_dir)
        end

      {:error, errors} ->
        Logger.error("Validation failed: #{inspect(errors)}")
        {:error, {:validation_failed, errors}}
    end
  end

  @doc """
  Returns the JSON representation without writing to disk.
  Useful for preview in LiveView.
  """
  def preview(%Book{} = book) do
    languages = Application.get_env(:pdf_pipeline, :default_languages, ~w(en fr de es ru ja zh))

    json =
      book
      |> Book.assign_ref_ids()
      |> Book.init_i18n(languages)
      |> Book.to_json()

    {:ok, json}
  end
end
