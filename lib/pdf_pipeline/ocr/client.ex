defmodule PdfPipeline.OCR.Client do
  @moduledoc """
  HTTP client for the GLM-OCR layout parsing API at api.z.ai.

  Sends PDFs for extraction and returns raw markdown/text output.
  """

  require Logger

  @api_url "https://api.z.ai/api/paas/v4/layout_parsing"

  @doc """
  Extracts text from a PDF file using GLM-OCR.

  ## Options
  - `:api_key` — Override the configured API key
  - `:timeout` — Request timeout in ms (default: 120_000)

  ## Returns
  - `{:ok, text}` — Extracted markdown text
  - `{:error, reason}` — Error with description
  """
  def extract(pdf_path, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:pdf_pipeline, :zai_api_key)

    unless api_key do
      raise "ZAI_API_KEY not configured. Set the ZAI_API_KEY environment variable."
    end

    timeout = opts[:timeout] || 120_000

    Logger.info("Starting OCR extraction for #{pdf_path}")

    with {:ok, file_content} <- File.read(pdf_path),
         encoded <- Base.encode64(file_content) do
      body = %{
        "model" => "glm-ocr",
        "file" => encoded,
        "filename" => Path.basename(pdf_path)
      }

      case Req.post(@api_url,
             json: body,
             headers: [{"Authorization", "Bearer #{api_key}"}],
             receive_timeout: timeout
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          PdfPipeline.OCR.Response.parse(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("OCR API returned status #{status}: #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("OCR API request failed: #{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Extracts text from a PDF given a URL instead of a local file path.
  """
  def extract_url(pdf_url, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:pdf_pipeline, :zai_api_key)

    unless api_key do
      raise "ZAI_API_KEY not configured. Set the ZAI_API_KEY environment variable."
    end

    timeout = opts[:timeout] || 120_000

    Logger.info("Starting OCR extraction for URL: #{pdf_url}")

    body = %{
      "model" => "glm-ocr",
      "file" => pdf_url
    }

    case Req.post(@api_url,
           json: body,
           headers: [{"Authorization", "Bearer #{api_key}"}],
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        PdfPipeline.OCR.Response.parse(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("OCR API returned status #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("OCR API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end
end
