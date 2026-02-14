defmodule Curator.Refiner.Prompts do
  @moduledoc """
  Structured prompts for LLM refinement tasks.

  Each function returns a prompt string for a specific refinement task,
  formatted for the Claude API.
  """

  @doc """
  Prompt for identifying speakers in a batch of dialogue paragraphs.
  """
  def identify_speakers(paragraphs, context \\ %{}) do
    known_speakers = Map.get(context, :known_speakers, [])
    book_title = Map.get(context, :book_title, "unknown")

    speakers_list =
      if known_speakers != [] do
        "Known speakers in this text: #{Enum.join(known_speakers, ", ")}."
      else
        "No known speakers provided."
      end

    paragraphs_text =
      paragraphs
      |> Enum.map(fn p ->
        "[Paragraph #{p.n}]: #{p.text}"
      end)
      |> Enum.join("\n\n")

    """
    You are analyzing paragraphs from "#{book_title}" to identify who is speaking in each one.

    #{speakers_list}

    For each paragraph, determine:
    1. Who is speaking (use exact speaker names from the known list when possible)
    2. If no specific speaker, use "Narrator" for narrative/descriptive text

    Respond in JSON format as an array of objects:
    [{"n": <paragraph_number>, "speaker": "<speaker_name>"}]

    Only include paragraphs where you can identify the speaker with reasonable confidence.

    Paragraphs to analyze:

    #{paragraphs_text}
    """
  end

  @doc """
  Prompt for refining chapter boundaries when the rule engine is uncertain.
  """
  def refine_chapters(text_segments, context \\ %{}) do
    book_title = Map.get(context, :book_title, "unknown")

    segments_text =
      text_segments
      |> Enum.with_index(1)
      |> Enum.map(fn {segment, idx} ->
        preview = String.slice(segment, 0, 200)
        "[Segment #{idx}]: #{preview}..."
      end)
      |> Enum.join("\n\n")

    """
    You are analyzing text segments from "#{book_title}" to determine chapter boundaries.

    The rule-based parser produced these segments, but some boundaries may be incorrect.
    Review the segments and identify which are genuine chapter starts.

    Respond in JSON format:
    [{"segment": <segment_number>, "is_chapter_start": true/false, "suggested_title": "<title or null>"}]

    Text segments:

    #{segments_text}
    """
  end

  @doc """
  Prompt for splitting or merging ambiguous paragraphs.
  """
  def refine_paragraphs(paragraphs, context \\ %{}) do
    book_title = Map.get(context, :book_title, "unknown")

    paragraphs_text =
      paragraphs
      |> Enum.map(fn p ->
        "[Paragraph #{p.n}]: #{p.text}"
      end)
      |> Enum.join("\n\n")

    """
    You are reviewing paragraphs from "#{book_title}" that the parser flagged as potentially
    incorrectly split or merged.

    For each paragraph, determine if it should be:
    - "keep" — paragraph boundaries are correct
    - "split" — should be split into multiple paragraphs (provide split points)
    - "merge_with_next" — should be merged with the following paragraph

    Respond in JSON format:
    [{"n": <paragraph_number>, "action": "keep|split|merge_with_next", "reason": "<brief reason>"}]

    Paragraphs to review:

    #{paragraphs_text}
    """
  end
end
