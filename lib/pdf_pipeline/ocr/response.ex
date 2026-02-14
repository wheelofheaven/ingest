defmodule PdfPipeline.OCR.Response do
  @moduledoc """
  Parses and normalizes GLM-OCR API responses.

  The API returns JSON with extracted content as markdown text.
  This module handles response parsing and text normalization.
  """

  require Logger

  @doc """
  Parses the OCR API response body into extracted text.

  Handles multiple response formats from the GLM-OCR API:
  - Layout parsing format: `md_results` field (primary)
  - Chat completions format: `choices[].message.content`
  - Legacy formats: `result.content`, `content`
  """
  def parse(%{"md_results" => content}) when is_binary(content) do
    {:ok, normalize_text(content)}
  end

  def parse(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    {:ok, normalize_text(content)}
  end

  def parse(%{"result" => %{"content" => content}}) do
    {:ok, normalize_text(content)}
  end

  def parse(%{"content" => content}) when is_binary(content) do
    {:ok, normalize_text(content)}
  end

  def parse(%{"error" => error}) do
    {:error, {:api_error, error}}
  end

  def parse(body) when is_binary(body) do
    {:ok, normalize_text(body)}
  end

  def parse(other) do
    Logger.warning("Unexpected OCR response format: #{inspect(other)}")
    {:error, {:unexpected_format, other}}
  end

  @doc """
  Normalizes OCR output text.

  - Normalizes line endings
  - Strips common OCR artifacts
  - Collapses excessive whitespace
  """
  def normalize_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace("\uFEFF", "")
    |> String.replace(~r/[ \t]+$(?=\n)/m, "")
    |> String.replace(~r/\n{4,}/, "\n\n\n")
    |> String.trim()
  end
end
