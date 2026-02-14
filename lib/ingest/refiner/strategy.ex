defmodule Ingest.Refiner.Strategy do
  @moduledoc """
  Decides which paragraphs need LLM refinement vs rule-based parsing.

  Only sends ambiguous content to the LLM to minimize API calls.
  """

  alias Ingest.Schema.{Book, Paragraph}
  alias Ingest.Refiner.LlmClient

  require Logger

  @batch_size 20

  @doc """
  Refines a book by sending low-confidence paragraphs to the LLM.

  Returns the updated book with refined speaker attributions.
  """
  def refine(%Book{} = book, opts \\ []) do
    threshold = opts[:threshold] ||
      Application.get_env(:ingest, :llm_confidence_threshold, 0.7)

    context = %{
      book_title: Map.get(book.titles, book.primary_lang, book.slug),
      known_speakers: extract_known_speakers(book)
    }

    chapters =
      Enum.map(book.chapters, fn chapter ->
        {clear, ambiguous} =
          Enum.split_with(chapter.paragraphs, &(!needs_refinement?(&1, threshold)))

        if ambiguous == [] do
          chapter
        else
          Logger.info(
            "Chapter #{chapter.n}: #{length(ambiguous)} paragraphs need refinement"
          )

          refined =
            ambiguous
            |> Enum.chunk_every(@batch_size)
            |> Enum.flat_map(&LlmClient.refine_batch(&1, context))

          all_paragraphs =
            (clear ++ refined)
            |> Enum.sort_by(& &1.n)

          %{chapter | paragraphs: all_paragraphs}
        end
      end)

    %{book | chapters: chapters}
  end

  @doc """
  Checks if a paragraph needs LLM refinement based on confidence threshold.
  """
  def needs_refinement?(%Paragraph{confidence: c}, threshold) when c < threshold, do: true
  def needs_refinement?(_, _), do: false

  @doc """
  Returns statistics about how many paragraphs need refinement.
  """
  def refinement_stats(%Book{} = book, threshold \\ 0.7) do
    all_paragraphs = Enum.flat_map(book.chapters, &Ingest.Schema.Chapter.all_paragraphs/1)
    total = length(all_paragraphs)
    ambiguous = Enum.count(all_paragraphs, &needs_refinement?(&1, threshold))

    %{
      total: total,
      clear: total - ambiguous,
      ambiguous: ambiguous,
      percentage_clear: if(total > 0, do: Float.round((total - ambiguous) / total * 100, 1), else: 100.0)
    }
  end

  defp extract_known_speakers(%Book{} = book) do
    book.chapters
    |> Enum.flat_map(&Ingest.Schema.Chapter.all_paragraphs/1)
    |> Enum.map(& &1.speaker)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
