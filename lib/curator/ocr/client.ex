defmodule Curator.OCR.Client do
  @moduledoc """
  HTTP client for the GLM-OCR layout parsing API at api.z.ai.

  Sends PDFs for extraction and returns raw markdown/text output.
  Automatically splits PDFs exceeding the 100-page API limit into
  chunks and combines the results.
  """

  require Logger

  @api_url "https://api.z.ai/api/paas/v4/layout_parsing"
  @max_pages 100

  @doc """
  Extracts text from a PDF file using GLM-OCR.

  PDFs over #{@max_pages} pages are automatically split into chunks,
  processed individually, and combined. Requires `qpdf` for splitting.

  ## Options
  - `:api_key` — Override the configured API key
  - `:timeout` — Request timeout in ms (default: 120_000)

  ## Returns
  - `{:ok, text}` — Extracted markdown text
  - `{:error, reason}` — Error with description
  """
  def extract(pdf_path, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:curator, :zai_api_key)

    unless api_key do
      raise "ZAI_API_KEY not configured. Set the ZAI_API_KEY environment variable."
    end

    Logger.info("Starting OCR extraction for #{pdf_path}")

    case page_count(pdf_path) do
      {:ok, pages} when pages > @max_pages ->
        Logger.info("PDF has #{pages} pages (limit: #{@max_pages}), splitting into chunks")
        extract_chunked(pdf_path, pages, api_key, opts)

      {:ok, pages} ->
        Logger.info("PDF has #{pages} pages, processing in single request")
        extract_single(pdf_path, api_key, opts)

      {:error, :qpdf_not_found} ->
        Logger.warning("qpdf not available, attempting single request (may fail if >#{@max_pages} pages)")
        extract_single(pdf_path, api_key, opts)
    end
  end

  @doc """
  Extracts text from a PDF given a URL instead of a local file path.
  """
  def extract_url(pdf_url, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:curator, :zai_api_key)

    unless api_key do
      raise "ZAI_API_KEY not configured. Set the ZAI_API_KEY environment variable."
    end

    timeout = opts[:timeout] || 120_000

    Logger.info("Starting OCR extraction for URL: #{pdf_url}")

    body = %{"model" => "glm-ocr", "file" => pdf_url}

    case Req.post(@api_url,
           json: body,
           headers: [{"Authorization", "Bearer #{api_key}"}],
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Curator.OCR.Response.parse(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("OCR API returned status #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("OCR API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # Single-file extraction (≤100 pages)

  defp extract_single(pdf_path, api_key, opts) do
    timeout = opts[:timeout] || 120_000

    with {:ok, file_content} <- File.read(pdf_path) do
      data_uri = "data:application/pdf;base64," <> Base.encode64(file_content)
      body = %{"model" => "glm-ocr", "file" => data_uri}

      case Req.post(@api_url,
             json: body,
             headers: [{"Authorization", "Bearer #{api_key}"}],
             receive_timeout: timeout
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          Curator.OCR.Response.parse(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("OCR API returned status #{status}: #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("OCR API request failed: #{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  # Chunked extraction (>100 pages)

  defp extract_chunked(pdf_path, total_pages, api_key, opts) do
    chunks = chunk_ranges(total_pages, @max_pages)
    Logger.info("Processing #{length(chunks)} chunks: #{inspect(chunks)}")

    tmp_dir = Path.join(System.tmp_dir!(), "curator_chunks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      results =
        chunks
        |> Enum.with_index(1)
        |> Enum.reduce_while([], fn {{first, last}, idx}, acc ->
          chunk_path = Path.join(tmp_dir, "chunk_#{idx}.pdf")
          Logger.info("Chunk #{idx}/#{length(chunks)}: pages #{first}-#{last}")

          case split_pdf(pdf_path, chunk_path, first, last) do
            :ok ->
              case extract_single(chunk_path, api_key, opts) do
                {:ok, text} ->
                  {:cont, [text | acc]}

                {:error, reason} ->
                  Logger.error("Chunk #{idx} failed: #{inspect(reason)}")
                  {:halt, {:error, {:chunk_failed, idx, reason}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:split_failed, reason}}}
          end
        end)

      case results do
        {:error, _} = error -> error
        texts -> {:ok, texts |> Enum.reverse() |> Enum.join("\n\n")}
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  # PDF utilities

  defp page_count(pdf_path) do
    case System.cmd("qpdf", ["--show-npages", pdf_path], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output |> String.trim() |> String.to_integer()}

      {_, _} ->
        {:error, :qpdf_not_found}
    end
  rescue
    ErlangError -> {:error, :qpdf_not_found}
  end

  defp split_pdf(input, output, first_page, last_page) do
    case System.cmd("qpdf", [
           input,
           "--pages", ".", "#{first_page}-#{last_page}", "--",
           output
         ], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, 3} -> :ok  # qpdf exit 3 = warnings but success
      {output, code} -> {:error, "qpdf exit #{code}: #{output}"}
    end
  end

  defp chunk_ranges(total_pages, chunk_size) do
    1..total_pages
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn chunk -> {List.first(chunk), List.last(chunk)} end)
  end
end
