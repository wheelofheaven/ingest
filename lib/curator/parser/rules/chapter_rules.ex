defmodule Curator.Parser.Rules.ChapterRules do
  @moduledoc """
  Chapter boundary detection rules.

  Applies regex patterns to identify chapter headings in OCR text,
  splitting the text into chapter segments.
  """

  @doc """
  Splits text into chapter segments based on the given patterns.

  Returns a list of `{title, content}` tuples.
  If no chapter headings are found, returns the entire text as a single untitled chapter.
  """
  def split_chapters(text, patterns) when is_list(patterns) do
    combined_pattern =
      patterns
      |> Enum.map(&"(?:#{&1})")
      |> Enum.join("|")

    regex = Regex.compile!(combined_pattern, "mi")

    # Find all heading positions
    matches = Regex.scan(regex, text, return: :index)

    case matches do
      [] ->
        [{nil, String.trim(text)}]

      _ ->
        build_from_matches(text, matches, regex)
    end
  end

  defp build_from_matches(text, matches, _regex) do
    # matches is a list of [{start, length}] tuples (each match is a list with one element)
    positions = Enum.map(matches, fn [{start, length}] -> {start, length} end)

    # Build chapters: each heading + content until next heading
    positions
    |> Enum.with_index()
    |> Enum.map(fn {{start, length}, idx} ->
      heading = String.slice(text, start, length)
      title = extract_title(heading)

      content_start = start + length
      content_end =
        case Enum.at(positions, idx + 1) do
          {next_start, _} -> next_start
          nil -> String.length(text)
        end

      content = String.slice(text, content_start, content_end - content_start)

      {title, String.trim(content)}
    end)
    |> prepend_preamble(text, positions)
  end

  # If there's content before the first chapter heading, add it as a preamble chapter
  defp prepend_preamble(chapters, text, [{first_start, _} | _]) do
    preamble = String.slice(text, 0, first_start) |> String.trim()

    if preamble != "" do
      [{nil, preamble} | chapters]
    else
      chapters
    end
  end

  defp prepend_preamble(chapters, _, _), do: chapters

  @doc """
  Extracts a clean chapter title from a raw heading match.
  Strips markdown heading markers and extra whitespace.
  """
  def extract_title(heading) do
    heading
    |> String.trim()
    |> String.replace(~r/^#+\s*/, "")
    |> String.trim()
  end
end
