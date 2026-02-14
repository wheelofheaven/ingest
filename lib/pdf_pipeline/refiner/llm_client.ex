defmodule PdfPipeline.Refiner.LlmClient do
  @moduledoc """
  LLM-based refinement of parsed content.
  Delegates to the unified LLM client.
  """

  alias PdfPipeline.LLM.Client

  require Logger

  @doc """
  Refines a batch of paragraphs by sending them to the LLM for speaker identification.
  """
  def refine_batch(paragraphs, context \\ %{}) do
    prompt = PdfPipeline.Refiner.Prompts.identify_speakers(paragraphs, context)

    case Client.chat_json(prompt) do
      {:ok, results} when is_list(results) ->
        apply_speaker_results(paragraphs, results)

      {:ok, _} ->
        Logger.warning("Unexpected LLM response format, returning original paragraphs")
        paragraphs

      {:error, reason} ->
        Logger.warning("LLM refinement failed: #{inspect(reason)}, returning original paragraphs")
        paragraphs
    end
  end

  defp apply_speaker_results(paragraphs, results) do
    results_map = Map.new(results, fn r -> {r["n"], r["speaker"]} end)

    Enum.map(paragraphs, fn para ->
      case Map.get(results_map, para.n) do
        nil -> para
        speaker -> %{para | speaker: speaker, confidence: 0.9}
      end
    end)
  end
end
