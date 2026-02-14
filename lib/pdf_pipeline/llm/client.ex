defmodule PdfPipeline.LLM.Client do
  @moduledoc """
  Unified LLM client supporting z.ai (default) and Anthropic providers.

  z.ai uses OpenAI-compatible chat completions API.
  Anthropic uses their native Messages API.
  """

  require Logger

  @zai_url "https://api.z.ai/api/paas/v4/chat/completions"
  @anthropic_url "https://api.anthropic.com/v1/messages"

  @zai_model "glm-4-plus"
  @anthropic_model "claude-sonnet-4-5-20250929"

  @doc """
  Sends a prompt to the configured LLM provider and returns the response text.

  ## Options
  - `:provider` — `:zai` (default) or `:anthropic`
  - `:model` — Override model name
  - `:max_tokens` — Max response tokens (default: 4096)
  - `:system` — System prompt
  """
  def chat(prompt, opts \\ []) do
    provider = opts[:provider] || default_provider()

    case provider do
      :zai -> chat_zai(prompt, opts)
      :anthropic -> chat_anthropic(prompt, opts)
      other -> {:error, {:unknown_provider, other}}
    end
  end

  @doc """
  Sends a prompt and parses the response as JSON.
  """
  def chat_json(prompt, opts \\ []) do
    case chat(prompt, opts) do
      {:ok, text} -> parse_json_response(text)
      error -> error
    end
  end

  # z.ai — OpenAI-compatible format
  defp chat_zai(prompt, opts) do
    api_key = Application.get_env(:pdf_pipeline, :zai_api_key)

    unless api_key do
      raise "ZAI_API_KEY not configured. Add it to your .env file."
    end

    model = opts[:model] || @zai_model
    max_tokens = opts[:max_tokens] || 4096

    messages =
      case opts[:system] do
        nil -> [%{"role" => "user", "content" => prompt}]
        sys -> [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => prompt}]
      end

    body = %{
      "model" => model,
      "messages" => messages,
      "max_tokens" => max_tokens,
      "temperature" => opts[:temperature] || 0.3,
      "stream" => false
    }

    case Req.post(@zai_url,
           json: body,
           headers: [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/json"}
           ],
           receive_timeout: opts[:timeout] || 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("z.ai API returned status #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("z.ai API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # Anthropic — native Messages API
  defp chat_anthropic(prompt, opts) do
    api_key = Application.get_env(:pdf_pipeline, :anthropic_api_key)

    unless api_key do
      raise "ANTHROPIC_API_KEY not configured. Add it to your .env file."
    end

    model = opts[:model] || @anthropic_model
    max_tokens = opts[:max_tokens] || 4096

    body = %{
      "model" => model,
      "max_tokens" => max_tokens,
      "messages" => [%{"role" => "user", "content" => prompt}]
    }

    body =
      case opts[:system] do
        nil -> body
        sys -> Map.put(body, "system", sys)
      end

    case Req.post(@anthropic_url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: opts[:timeout] || 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Anthropic API returned status #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp default_provider do
    cond do
      Application.get_env(:pdf_pipeline, :zai_api_key) -> :zai
      Application.get_env(:pdf_pipeline, :anthropic_api_key) -> :anthropic
      true -> :zai
    end
  end

  defp parse_json_response(text) do
    json_text =
      case Regex.run(~r/```(?:json)?\s*\n?([\s\S]*?)\n?```/, text) do
        [_, json] -> json
        nil -> text
      end

    case Jason.decode(String.trim(json_text)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, {:json_parse_failed, text}}
    end
  end
end
