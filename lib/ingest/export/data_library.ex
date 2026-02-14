defmodule Ingest.Export.DataLibrary do
  @moduledoc """
  Exports a Book struct to data-library JSON format.

  Chooses between single-file and split-file format based on size.
  """

  alias Ingest.Schema.{Book, Validator}
  alias Ingest.Export.{SingleFile, SplitFile}

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
    output_dir = output_dir || Application.get_env(:ingest, :data_library_path, "../data-library")
    languages = Application.get_env(:ingest, :default_languages, ~w(en fr de es ru ja zh))

    book =
      book
      |> Book.assign_ref_ids()
      |> Book.init_i18n(languages)

    json = Book.to_json(book) |> strip_internal_keys()

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
    languages = Application.get_env(:ingest, :default_languages, ~w(en fr de es ru ja zh))

    json =
      book
      |> Book.assign_ref_ids()
      |> Book.init_i18n(languages)
      |> Book.to_json()
      |> strip_internal_keys()

    {:ok, json}
  end

  defp strip_internal_keys(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _} -> is_binary(key) and String.starts_with?(key, "_") end)
    |> Map.new(fn {key, val} -> {key, strip_internal_keys(val)} end)
  end

  defp strip_internal_keys(list) when is_list(list) do
    Enum.map(list, &strip_internal_keys/1)
  end

  defp strip_internal_keys(value), do: value
end
