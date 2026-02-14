defmodule PdfPipeline.Parser.Rules.SpeakerRules do
  @moduledoc """
  Speaker detection and attribution rules.

  Identifies who is speaking in dialogue paragraphs using
  configurable patterns (em-dash dialogue, known speaker names, etc.)
  """

  @doc """
  Applies speaker detection rules to a list of paragraphs.

  Returns updated paragraphs with speaker attribution where detected.
  Paragraphs where speaker detection is ambiguous get lower confidence.
  """
  def detect_speakers(paragraphs, rules) do
    speaker_config = Map.get(rules, "speaker_patterns", %{})
    known_speakers = Map.get(speaker_config, "known_speakers", [])
    dialogue_dash = Map.get(speaker_config, "dialogue_dash", "^[—–]\\s*")
    default_speaker = Map.get(rules, "default_speaker", "Narrator")

    Enum.map(paragraphs, fn para ->
      cond do
        speaker_from_known(para.text, known_speakers) ->
          speaker = speaker_from_known(para.text, known_speakers)
          %{para | speaker: speaker}

        dialogue_match?(para.text, dialogue_dash) ->
          # Dialogue detected but speaker unknown — lower confidence
          %{para | speaker: nil, confidence: min(para.confidence, 0.5)}

        true ->
          %{para | speaker: default_speaker}
      end
    end)
  end

  @doc """
  Checks if text starts with a known speaker pattern like "Yahweh: ..." or "[Yahweh]".
  """
  def speaker_from_known(text, known_speakers) do
    Enum.find(known_speakers, fn speaker ->
      patterns = [
        ~r/^#{Regex.escape(speaker)}\s*:/iu,
        ~r/^\[#{Regex.escape(speaker)}\]/iu,
        ~r/^«\s*#{Regex.escape(speaker)}/iu
      ]

      Enum.any?(patterns, &Regex.match?(&1, text))
    end)
  end

  @doc """
  Checks if text matches a dialogue pattern (e.g., starts with em-dash).
  """
  def dialogue_match?(text, pattern) do
    regex = Regex.compile!(pattern)
    Regex.match?(regex, text)
  end
end
