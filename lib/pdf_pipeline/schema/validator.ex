defmodule PdfPipeline.Schema.Validator do
  @moduledoc """
  Validates book data against the data-library JSON schema.
  """

  @doc """
  Validates a book JSON map against the book schema.

  Returns `{:ok, json}` if valid, `{:error, errors}` if invalid.
  """
  def validate_book(json) when is_map(json) do
    schema = book_schema()
    resolved = ExJsonSchema.Schema.resolve(schema)

    case ExJsonSchema.Validator.validate(resolved, json) do
      :ok -> {:ok, json}
      {:error, errors} -> {:error, format_errors(errors)}
    end
  end

  @doc """
  Validates a chapter JSON map.
  """
  def validate_chapter(json) when is_map(json) do
    schema = chapter_schema()
    resolved = ExJsonSchema.Schema.resolve(schema)

    case ExJsonSchema.Validator.validate(resolved, json) do
      :ok -> {:ok, json}
      {:error, errors} -> {:error, format_errors(errors)}
    end
  end

  defp format_errors(errors) do
    Enum.map(errors, fn {message, path} ->
      "#{path}: #{message}"
    end)
  end

  defp book_schema do
    %{
      "type" => "object",
      "required" => [
        "slug",
        "code",
        "primaryLang",
        "titles",
        "schema",
        "revision",
        "updated",
        "chapters",
        "refId",
        "paragraphCount",
        "chapterCount"
      ],
      "properties" => %{
        "slug" => %{"type" => "string", "pattern" => "^[a-z0-9-]+$"},
        "code" => %{"type" => "string", "pattern" => "^[A-Z0-9]+$"},
        "primaryLang" => %{"type" => "string", "minLength" => 2, "maxLength" => 10},
        "titles" => %{"type" => "object"},
        "publicationYear" => %{"type" => ["integer", "null"]},
        "schema" => %{
          "type" => "array",
          "items" => %{"type" => "string"}
        },
        "revision" => %{"type" => "integer", "minimum" => 1},
        "updated" => %{"type" => "string"},
        "chapters" => %{
          "type" => "array",
          "items" => chapter_schema()
        },
        "refId" => %{"type" => "string"},
        "paragraphCount" => %{"type" => "integer", "minimum" => 0},
        "chapterCount" => %{"type" => "integer", "minimum" => 0}
      }
    }
  end

  defp chapter_schema do
    %{
      "type" => "object",
      "required" => ["n", "title", "i18n", "paragraphs", "refId"],
      "properties" => %{
        "n" => %{"type" => "integer", "minimum" => 1},
        "title" => %{"type" => "string"},
        "i18n" => %{"type" => "object"},
        "paragraphs" => %{
          "type" => "array",
          "items" => paragraph_schema()
        },
        "refId" => %{"type" => "string"}
      }
    }
  end

  defp paragraph_schema do
    %{
      "type" => "object",
      "required" => ["n", "text", "i18n", "refId"],
      "properties" => %{
        "n" => %{"type" => "integer", "minimum" => 1},
        "speaker" => %{"type" => ["string", "null"]},
        "text" => %{"type" => "string"},
        "i18n" => %{"type" => "object"},
        "refId" => %{"type" => "string"}
      }
    }
  end
end
