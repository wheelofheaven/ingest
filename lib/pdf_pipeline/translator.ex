defmodule PdfPipeline.Translator do
  @moduledoc """
  LLM-based translation of structured book content.

  Translates paragraphs and chapter titles into target languages,
  preserving religious/philosophical terms that should not be translated.
  """

  alias PdfPipeline.LLM.Client
  alias PdfPipeline.Schema.{Book, Chapter}

  require Logger

  @batch_size 15
  @preserve_terms ~w(Elohim Yahweh Raël Satan)

  @doc """
  Translates a book's content into the specified target languages.

  ## Parameters
  - `book` — The `%Book{}` to translate
  - `target_langs` — List of ISO 639-1 codes (e.g., `["en", "de", "es"]`)
  - `opts` — Options:
    - `:preserve_terms` — Additional terms to keep untranslated

  ## Returns
  - `{:ok, %Book{}}` — Book with i18n slots filled
  """
  def translate(%Book{} = book, target_langs, opts \\ []) do
    source_lang = book.primary_lang
    # Don't translate into the source language
    langs = Enum.reject(target_langs, &(&1 == source_lang))

    if langs == [] do
      Logger.info("[Translate] No target languages to translate to")
      {:ok, book}
    else
      Logger.info("[Translate] Translating from #{source_lang} to #{Enum.join(langs, ", ")}")
      preserve = Keyword.get(opts, :preserve_terms, []) ++ @preserve_terms

      chapters =
        book.chapters
        |> Enum.with_index(1)
        |> Enum.map(fn {chapter, idx} ->
          Logger.info("[Translate] Chapter #{idx}/#{length(book.chapters)}: #{chapter.title}")
          translate_chapter(chapter, source_lang, langs, preserve)
        end)

      {:ok, %{book | chapters: chapters}}
    end
  end

  @doc """
  Translates a single chapter (title + paragraphs) into target languages.
  """
  def translate_chapter(%Chapter{} = chapter, source_lang, target_langs, preserve_terms) do
    Enum.reduce(target_langs, chapter, fn lang, ch ->
      translate_chapter_to(ch, source_lang, lang, preserve_terms)
    end)
  end

  defp translate_chapter_to(chapter, source_lang, target_lang, preserve_terms) do
    # Translate chapter title
    title_i18n =
      case translate_text(chapter.title, source_lang, target_lang, preserve_terms) do
        {:ok, translated} -> Map.put(chapter.i18n, target_lang, translated)
        {:error, _} -> chapter.i18n
      end

    # Translate paragraphs in batches
    paragraphs =
      chapter.paragraphs
      |> Enum.chunk_every(@batch_size)
      |> Enum.flat_map(fn batch ->
        translate_paragraph_batch(batch, source_lang, target_lang, preserve_terms)
      end)

    %{chapter | i18n: title_i18n, paragraphs: paragraphs}
  end

  defp translate_paragraph_batch(paragraphs, source_lang, target_lang, preserve_terms) do
    prompt = build_batch_prompt(paragraphs, source_lang, target_lang, preserve_terms)

    case Client.chat_json(prompt) do
      {:ok, results} when is_list(results) ->
        apply_translations(paragraphs, results, target_lang)

      {:ok, _} ->
        Logger.warning("[Translate] Unexpected response format, skipping batch")
        paragraphs

      {:error, reason} ->
        Logger.warning("[Translate] Batch translation failed: #{inspect(reason)}, skipping")
        paragraphs
    end
  end

  defp build_batch_prompt(paragraphs, source_lang, target_lang, preserve_terms) do
    lang_names = %{
      "en" => "English",
      "fr" => "French",
      "de" => "German",
      "es" => "Spanish",
      "ru" => "Russian",
      "ja" => "Japanese",
      "zh" => "Chinese (Simplified)"
    }

    source_name = Map.get(lang_names, source_lang, source_lang)
    target_name = Map.get(lang_names, target_lang, target_lang)

    preserve_list =
      if preserve_terms != [] do
        "IMPORTANT: Keep these terms untranslated (they are proper nouns): #{Enum.join(preserve_terms, ", ")}"
      else
        ""
      end

    texts =
      paragraphs
      |> Enum.map(fn p -> ~s({"n": #{p.n}, "text": #{Jason.encode!(p.text)}}) end)
      |> Enum.join(",\n")

    """
    Translate the following paragraphs from #{source_name} to #{target_name}.
    #{preserve_list}

    Maintain the original meaning, tone, and style. This is a religious/philosophical text,
    so preserve the scholarly tone. Do not add or remove content.

    Input paragraphs (JSON array):
    [#{texts}]

    Respond with a JSON array of objects, each with "n" (paragraph number) and "text" (translated text):
    [{"n": 1, "text": "translated text"}, ...]
    """
  end

  defp apply_translations(paragraphs, results, target_lang) do
    results_map = Map.new(results, fn r -> {r["n"], r["text"]} end)

    Enum.map(paragraphs, fn para ->
      case Map.get(results_map, para.n) do
        nil -> para
        translated -> %{para | i18n: Map.put(para.i18n, target_lang, translated)}
      end
    end)
  end

  @doc """
  Translates a single text string.
  """
  def translate_text(text, source_lang, target_lang, preserve_terms \\ []) do
    if String.trim(text) == "" do
      {:ok, ""}
    else
      prompt = """
      Translate the following text from #{source_lang} to #{target_lang}.
      Keep these terms untranslated: #{Enum.join(preserve_terms, ", ")}.
      Respond with ONLY the translated text, no explanations.

      Text: #{text}
      """

      Client.chat(prompt)
    end
  end
end
