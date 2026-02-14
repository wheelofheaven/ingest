defmodule IngestWeb.EditorLive do
  use IngestWeb, :live_view

  alias Ingest.Store.Job
  alias Ingest.Schema.{Book, Chapter, Paragraph}
  alias Ingest.Stages.{WorkDir, Normalize}

  @impl true
  def mount(params, _session, socket) do
    case load_book(params) do
      {:ok, book, slug, source} ->
        repeated = detect_repeated_patterns(book)
        speakers = load_speakers(book)

        {:ok,
         socket
         |> assign(:book, book)
         |> assign(:saved_book, book)
         |> assign(:slug, slug)
         |> assign(:source, source)
         |> assign(:speakers, speakers)
         |> assign(:selected_chapter, 1)
         |> assign(:editing_paragraph, nil)
         |> assign(:editing_chapter, nil)
         |> assign(:focused_ref, nil)
         |> assign(:selected_refs, MapSet.new())
         |> assign(:repeated_patterns, repeated)
         |> assign(:show_patterns, false)
         |> assign(:dirty, false)
         |> assign(:page_title, "Edit: #{slug}")}

      {:error, message} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: ~p"/")}
    end
  end

  defp load_book(%{"slug" => slug}) do
    case Normalize.load_book(slug) do
      {:ok, book} -> {:ok, book, slug, :work_dir}
      {:error, _} -> {:error, "No book.json found for #{slug}"}
    end
  end

  defp load_book(%{"job_id" => job_id}) do
    case Job.get(job_id) do
      {:ok, %{book: nil}} -> {:error, "Book not yet parsed"}
      {:ok, %{book: book, metadata: meta}} -> {:ok, book, meta[:slug], {:job, job_id}}
      {:error, :not_found} -> {:error, "Job not found"}
    end
  end

  # -- Scroll-based focus --

  @impl true
  def handle_event("scroll_focus", %{"ref-id" => ref_id}, socket) do
    {:noreply, assign(socket, :focused_ref, ref_id)}
  end

  # -- Chapter navigation --

  def handle_event("select_chapter", %{"chapter" => chapter}, socket) do
    {:noreply,
     socket
     |> assign(:selected_chapter, String.to_integer(chapter))
     |> assign(:editing_paragraph, nil)
     |> assign(:focused_ref, nil)
     |> assign(:selected_refs, MapSet.new())}
  end

  # -- Paragraph editing --

  def handle_event("edit_paragraph", %{"ref-id" => ref_id}, socket) do
    {:noreply, assign(socket, :editing_paragraph, ref_id)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_paragraph, nil)}
  end

  def handle_event("save_paragraph", %{"ref_id" => ref_id, "text" => text, "speaker" => speaker}, socket) do
    speaker = if speaker == "", do: nil, else: speaker

    book = update_paragraph(socket.assigns.book, ref_id, fn para ->
      %{para | text: String.trim(text), speaker: speaker, confidence: 1.0}
    end)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:editing_paragraph, nil)
     |> assign(:dirty, true)}
  end

  # -- Delete paragraph --

  def handle_event("delete_paragraph", %{"ref-id" => ref_id}, socket) do
    book = delete_paragraphs(socket.assigns.book, [ref_id])

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> assign(:repeated_patterns, detect_repeated_patterns(book))}
  end

  # -- Multi-select --

  def handle_event("toggle_select", %{"ref-id" => ref_id}, socket) do
    selected = socket.assigns.selected_refs

    selected =
      if MapSet.member?(selected, ref_id),
        do: MapSet.delete(selected, ref_id),
        else: MapSet.put(selected, ref_id)

    {:noreply, assign(socket, :selected_refs, selected)}
  end

  def handle_event("select_all_chapter", _params, socket) do
    chapter = get_chapter(socket.assigns.book, socket.assigns.selected_chapter)

    refs =
      if chapter,
        do: MapSet.new(Enum.map(chapter.paragraphs, & &1.ref_id)),
        else: MapSet.new()

    {:noreply, assign(socket, :selected_refs, refs)}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected_refs, MapSet.new())}
  end

  def handle_event("delete_selected", _params, socket) do
    refs = MapSet.to_list(socket.assigns.selected_refs)
    count = length(refs)

    if count > 0 do
      book = delete_paragraphs(socket.assigns.book, refs)

      {:noreply,
       socket
       |> assign(:book, book)
       |> assign(:selected_refs, MapSet.new())
       |> assign(:dirty, true)
       |> assign(:repeated_patterns, detect_repeated_patterns(book))
       |> put_flash(:info, "Deleted #{count} paragraphs")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_speaker_selected", %{"speaker" => speaker}, socket) do
    speaker = if speaker == "", do: nil, else: speaker
    refs = socket.assigns.selected_refs

    book =
      Enum.reduce(refs, socket.assigns.book, fn ref_id, book ->
        update_paragraph(book, ref_id, fn para -> %{para | speaker: speaker} end)
      end)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_refs, MapSet.new())
     |> assign(:dirty, true)
     |> put_flash(:info, "Speaker set for #{MapSet.size(refs)} paragraphs")}
  end

  # -- Repeated patterns --

  def handle_event("toggle_patterns", _params, socket) do
    {:noreply, assign(socket, :show_patterns, !socket.assigns.show_patterns)}
  end

  def handle_event("remove_pattern", %{"pattern" => pattern}, socket) do
    book = socket.assigns.book

    matching_refs =
      book.chapters
      |> Enum.flat_map(& &1.paragraphs)
      |> Enum.filter(fn p -> String.trim(p.text) == pattern end)
      |> Enum.map(& &1.ref_id)

    book = delete_paragraphs(book, matching_refs)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> assign(:repeated_patterns, detect_repeated_patterns(book))
     |> put_flash(:info, "Removed #{length(matching_refs)} occurrences")}
  end

  def handle_event("select_pattern", %{"pattern" => pattern}, socket) do
    book = socket.assigns.book

    matching_refs =
      book.chapters
      |> Enum.flat_map(& &1.paragraphs)
      |> Enum.filter(fn p -> String.trim(p.text) == pattern end)
      |> Enum.map(& &1.ref_id)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_refs, matching_refs)}
  end

  # -- Merge with next --

  def handle_event("merge_with_next", %{"ref-id" => ref_id}, socket) do
    chapter_n = socket.assigns.selected_chapter
    book = socket.assigns.book

    updated_chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == chapter_n, do: merge_paragraphs(chapter, ref_id), else: chapter
      end)

    book = %{book | chapters: updated_chapters} |> Book.assign_ref_ids()

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)}
  end

  # -- Speaker list management --

  def handle_event("add_speaker_option", %{"speaker" => name}, socket) do
    name = String.trim(name)

    if name != "" and name not in socket.assigns.speakers do
      speakers = (socket.assigns.speakers ++ [name]) |> Enum.sort()
      {:noreply, assign(socket, :speakers, speakers)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_speaker_option", %{"speaker" => name}, socket) do
    speakers = Enum.reject(socket.assigns.speakers, &(&1 == name))
    {:noreply, assign(socket, :speakers, speakers)}
  end

  # -- Quick speaker set --

  def handle_event("set_speaker", %{"ref-id" => ref_id, "speaker" => speaker}, socket) do
    speaker = if speaker == "", do: nil, else: speaker

    book = update_paragraph(socket.assigns.book, ref_id, fn para ->
      %{para | speaker: speaker}
    end)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)}
  end

  # -- Glue / merge paragraphs (between-paragraph action) --

  def handle_event("glue_paragraphs", %{"ref-id" => ref_id}, socket) do
    chapter_n = socket.assigns.selected_chapter
    book = socket.assigns.book

    # ref_id is the SECOND paragraph — we merge the one BEFORE it with this one
    chapter = get_chapter(book, chapter_n)

    if chapter do
      idx = Enum.find_index(chapter.paragraphs, &(&1.ref_id == ref_id))

      if idx && idx > 0 do
        prev = Enum.at(chapter.paragraphs, idx - 1)
        book = glue_paragraph_pair(book, chapter_n, prev.ref_id)

        {:noreply,
         socket
         |> assign(:book, book)
         |> assign(:dirty, true)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # -- Chapter break insertion --

  def handle_event("insert_chapter_break", %{"ref-id" => ref_id}, socket) do
    book = socket.assigns.book
    chapter_n = socket.assigns.selected_chapter
    book = split_chapter_at_paragraph(book, chapter_n, ref_id)

    # The new chapter is chapter_n + 1 — switch to it and open title editing
    new_chapter_n = chapter_n + 1

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_chapter, new_chapter_n)
     |> assign(:editing_chapter, new_chapter_n)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter break inserted — name your new chapter")}
  end

  # -- Chapter editing --

  def handle_event("rename_chapter", %{"chapter" => n_str, "title" => title}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book

    chapters =
      Enum.map(book.chapters, fn ch ->
        if ch.n == n, do: %{ch | title: String.trim(title)}, else: ch
      end)

    {:noreply,
     socket
     |> assign(:book, %{book | chapters: chapters})
     |> assign(:editing_chapter, nil)
     |> assign(:dirty, true)}
  end

  def handle_event("edit_chapter_title", %{"chapter" => n_str}, socket) do
    {:noreply, assign(socket, :editing_chapter, String.to_integer(n_str))}
  end

  def handle_event("cancel_edit_chapter", _params, socket) do
    {:noreply, assign(socket, :editing_chapter, nil)}
  end

  def handle_event("remove_chapter_break", %{"chapter" => n_str}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book

    if n > 1 do
      book = merge_chapters(book, n - 1)

      {:noreply,
       socket
       |> assign(:book, book)
       |> assign(:selected_chapter, n - 1)
       |> assign(:dirty, true)
       |> put_flash(:info, "Chapter break removed")}
    else
      {:noreply, put_flash(socket, :error, "Cannot remove the first chapter break")}
    end
  end

  def handle_event("delete_chapter", %{"chapter" => n_str}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book

    chapters = Enum.reject(book.chapters, &(&1.n == n))
    book = %{book | chapters: chapters} |> Book.assign_ref_ids()

    new_selected = min(socket.assigns.selected_chapter, length(chapters))
    new_selected = max(new_selected, 1)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_chapter, new_selected)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter deleted")}
  end

  # -- Save --

  def handle_event("save_to_disk", _params, socket) do
    book = socket.assigns.book
    slug = socket.assigns.slug
    json = Book.to_json(book)
    encoded = Jason.encode!(json, pretty: true)
    {:ok, path} = WorkDir.write_artifact(slug, "book.json", encoded)

    case socket.assigns.source do
      {:job, job_id} -> Job.update(job_id, %{book: book})
      _ -> :ok
    end

    {:noreply,
     socket
     |> assign(:saved_book, book)
     |> assign(:dirty, false)
     |> put_flash(:info, "Saved to #{path}")}
  end

  # -- Private helpers --

  defp get_chapter(book, n) do
    Enum.find(book.chapters, &(&1.n == n))
  end

  defp find_paragraph(book, ref_id) do
    book.chapters
    |> Enum.flat_map(& &1.paragraphs)
    |> Enum.find(&(&1.ref_id == ref_id))
  end

  defp update_paragraph(book, ref_id, update_fn) do
    chapters =
      Enum.map(book.chapters, fn chapter ->
        paragraphs =
          Enum.map(chapter.paragraphs, fn para ->
            if para.ref_id == ref_id, do: update_fn.(para), else: para
          end)

        %{chapter | paragraphs: paragraphs}
      end)

    %{book | chapters: chapters}
  end

  defp delete_paragraphs(book, ref_ids) do
    ref_set = MapSet.new(ref_ids)

    chapters =
      Enum.map(book.chapters, fn chapter ->
        paragraphs = Enum.reject(chapter.paragraphs, &MapSet.member?(ref_set, &1.ref_id))
        %{chapter | paragraphs: paragraphs}
      end)

    %{book | chapters: chapters} |> Book.assign_ref_ids()
  end

  defp merge_paragraphs(chapter, ref_id) do
    paragraphs = chapter.paragraphs
    idx = Enum.find_index(paragraphs, &(&1.ref_id == ref_id))

    if idx && idx < length(paragraphs) - 1 do
      current = Enum.at(paragraphs, idx)
      next = Enum.at(paragraphs, idx + 1)
      merged = %{current | text: current.text <> "\n\n" <> next.text}

      paragraphs
      |> List.delete_at(idx + 1)
      |> List.replace_at(idx, merged)
      |> then(&%{chapter | paragraphs: &1})
    else
      chapter
    end
  end

  defp split_chapter_at_paragraph(book, chapter_n, ref_id) do
    chapters =
      Enum.flat_map(book.chapters, fn chapter ->
        if chapter.n == chapter_n do
          case Enum.find_index(chapter.paragraphs, &(&1.ref_id == ref_id)) do
            nil ->
              [chapter]

            0 ->
              [chapter]

            idx ->
              {before_paras, after_paras} = Enum.split(chapter.paragraphs, idx)

              first_para = List.first(after_paras)

              new_title =
                if first_para,
                  do: String.slice(first_para.text, 0, 60) |> String.trim(),
                  else: "New Chapter"

              [
                %{chapter | paragraphs: before_paras},
                Chapter.new(%{n: chapter.n + 1, title: new_title, paragraphs: after_paras})
              ]
          end
        else
          [chapter]
        end
      end)

    %{book | chapters: chapters} |> Book.assign_ref_ids()
  end

  defp merge_chapters(book, chapter_n) do
    chapters = book.chapters
    idx = Enum.find_index(chapters, &(&1.n == chapter_n))

    if idx && idx < length(chapters) - 1 do
      current = Enum.at(chapters, idx)
      next = Enum.at(chapters, idx + 1)
      merged = %{current | paragraphs: current.paragraphs ++ next.paragraphs}

      chapters
      |> List.delete_at(idx + 1)
      |> List.replace_at(idx, merged)
      |> then(&%{book | chapters: &1})
      |> Book.assign_ref_ids()
    else
      book
    end
  end

  defp load_speakers(book) do
    # Collect speakers from all rule profiles
    rules_speakers =
      Path.wildcard("priv/rules/*.json")
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, content} ->
            json = Jason.decode!(content)
            get_in(json, ["speaker_patterns", "known_speakers"]) || []

          _ ->
            []
        end
      end)

    # Collect speakers already in the book
    book_speakers =
      book.chapters
      |> Enum.flat_map(& &1.paragraphs)
      |> Enum.map(& &1.speaker)
      |> Enum.reject(&is_nil/1)

    # Combine, deduplicate, ensure Narrator is included
    (["Narrator"] ++ rules_speakers ++ book_speakers)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp glue_paragraph_pair(book, chapter_n, ref_id) do
    updated_chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == chapter_n, do: merge_paragraphs(chapter, ref_id), else: chapter
      end)

    %{book | chapters: updated_chapters} |> Book.assign_ref_ids()
  end

  defp speaker_initials(speaker) do
    speaker
    |> String.split(~r/\s+/)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp detect_repeated_patterns(book) do
    book.chapters
    |> Enum.flat_map(& &1.paragraphs)
    |> Enum.map(fn p -> String.trim(p.text) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.filter(fn {_text, count} -> count >= 3 end)
    |> Enum.sort_by(fn {_text, count} -> -count end)
    |> Enum.map(fn {text, count} -> %{text: text, count: count, short: String.slice(text, 0, 80)} end)
  end

  defp compute_changes(saved_book, current_book) do
    saved_ch = Book.chapter_count(saved_book)
    current_ch = Book.chapter_count(current_book)
    saved_p = Book.paragraph_count(saved_book)
    current_p = Book.paragraph_count(current_book)

    saved_texts =
      saved_book.chapters
      |> Enum.flat_map(& &1.paragraphs)
      |> MapSet.new(& &1.text)

    current_texts =
      current_book.chapters
      |> Enum.flat_map(& &1.paragraphs)
      |> MapSet.new(& &1.text)

    added = MapSet.difference(current_texts, saved_texts) |> MapSet.size()
    removed = MapSet.difference(saved_texts, current_texts) |> MapSet.size()

    %{
      ch_saved: saved_ch,
      ch_current: current_ch,
      p_saved: saved_p,
      p_current: current_p,
      added: added,
      removed: removed,
      has_changes: saved_ch != current_ch || saved_p != current_p || added > 0 || removed > 0
    }
  end

  defp focused_paragraph_json(book, ref_id) do
    case find_paragraph(book, ref_id) do
      nil -> nil
      para -> Paragraph.to_json(para) |> Jason.encode!(pretty: true)
    end
  end

  defp focused_chapter_json(chapter) do
    %{
      "n" => chapter.n,
      "title" => chapter.title,
      "refId" => chapter.ref_id,
      "paragraphCount" => length(chapter.paragraphs)
    }
    |> Jason.encode!(pretty: true)
  end

  # -- Render --

  @impl true
  def render(assigns) do
    chapter = get_chapter(assigns.book, assigns.selected_chapter)
    changes = compute_changes(assigns.saved_book, assigns.book)

    assigns =
      assigns
      |> assign(:chapter, chapter)
      |> assign(:selected_count, MapSet.size(assigns.selected_refs))
      |> assign(:changes, changes)
      |> assign(:para_json, focused_paragraph_json(assigns.book, assigns.focused_ref))
      |> assign(:ch_json, if(chapter, do: focused_chapter_json(chapter), else: nil))

    ~H"""
    <IngestWeb.Layouts.app flash={@flash} container_class="mx-auto max-w-[96rem]">
      <div class="space-y-3">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold">{@slug}</h1>
            <p class="text-base-content/50 text-xs">
              {Book.chapter_count(@book)} chapters · {Book.paragraph_count(@book)} paragraphs
            </p>
          </div>
          <div class="flex gap-2 items-center">
            <%= if @dirty do %>
              <span class="badge badge-warning badge-xs">unsaved</span>
            <% end %>
            <button phx-click="save_to_disk" class={"btn btn-sm #{if @dirty, do: "btn-warning", else: "btn-ghost"}"}>
              Save
            </button>
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Back</.link>
          </div>
        </div>

        <%!-- Repeated patterns --%>
        <%= if @repeated_patterns != [] do %>
          <div class="bg-base-200 rounded-lg p-3">
            <button phx-click="toggle_patterns" class="flex items-center gap-2 w-full text-left text-sm">
              <span class="font-semibold">{length(@repeated_patterns)} repeated patterns</span>
              <span class="text-base-content/40 text-xs">(page headers/footers)</span>
              <span class="ml-auto text-xs">{if @show_patterns, do: "Hide", else: "Show"}</span>
            </button>
            <%= if @show_patterns do %>
              <div class="mt-2 space-y-1">
                <%= for pattern <- @repeated_patterns do %>
                  <div class="flex items-center gap-2 bg-base-100 rounded p-2 text-sm">
                    <span class="flex-1 font-mono text-xs truncate">{pattern.short}</span>
                    <span class="badge badge-ghost badge-xs">{pattern.count}x</span>
                    <button phx-click="select_pattern" phx-value-pattern={pattern.text} class="btn btn-ghost btn-xs">Select</button>
                    <button phx-click="remove_pattern" phx-value-pattern={pattern.text} class="btn btn-error btn-xs" data-confirm={"Remove all #{pattern.count} occurrences?"}>Remove</button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Bulk actions --%>
        <%= if @selected_count > 0 do %>
          <div class="sticky top-0 z-10 bg-base-300 rounded-lg p-2 flex items-center gap-3 shadow-lg text-sm">
            <span class="font-semibold">{@selected_count} selected</span>
            <button phx-click="select_none" class="btn btn-ghost btn-xs">Clear</button>
            <div class="divider divider-horizontal mx-0"></div>
            <button phx-click="delete_selected" class="btn btn-error btn-xs" data-confirm={"Delete #{@selected_count} paragraphs?"}>Delete</button>
            <form phx-submit="set_speaker_selected" class="flex items-center gap-1">
              <input type="text" name="speaker" placeholder="Speaker..." class="input input-bordered input-xs w-32" />
              <button type="submit" class="btn btn-xs btn-ghost">Set</button>
            </form>
          </div>
        <% end %>

        <%!-- Three-column layout --%>
        <div class="flex gap-4">
          <%!-- Left: Chapter sidebar --%>
          <div class="w-48 shrink-0 hidden lg:block">
            <div class="sticky top-2">
              <h3 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-2">Chapters</h3>
              <ul class="space-y-0.5">
                <%= for ch <- @book.chapters do %>
                  <li>
                    <%= if @editing_chapter == ch.n do %>
                      <form phx-submit="rename_chapter" class="px-2 py-1">
                        <input type="hidden" name="chapter" value={ch.n} />
                        <input type="text" name="title" value={ch.title} class="input input-bordered input-xs w-full mb-1" autofocus />
                        <div class="flex gap-1">
                          <button type="submit" class="btn btn-primary btn-xs flex-1">Save</button>
                          <button type="button" phx-click="cancel_edit_chapter" class="btn btn-ghost btn-xs">Cancel</button>
                        </div>
                      </form>
                    <% else %>
                      <div class="group flex items-center gap-1">
                        <button
                          phx-click="select_chapter"
                          phx-value-chapter={ch.n}
                          class={"flex items-center gap-1.5 flex-1 text-left px-2 py-1 rounded text-sm hover:bg-base-200 transition-colors #{if @selected_chapter == ch.n, do: "bg-base-200 font-medium", else: ""}"}
                        >
                          <span class="text-base-content/30 font-mono text-xs w-5 text-right shrink-0">{ch.n}</span>
                          <span class="truncate flex-1">{ch.title}</span>
                          <span class="text-base-content/30 text-xs">{length(ch.paragraphs)}</span>
                        </button>
                        <button
                          phx-click="edit_chapter_title"
                          phx-value-chapter={ch.n}
                          class="hidden group-hover:block btn btn-ghost btn-xs px-1"
                          title="Rename chapter"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3"><path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.05 7.475a.75.75 0 0 0-.186.312l-.9 3.15a.75.75 0 0 0 .926.926l3.15-.9a.75.75 0 0 0 .312-.186l4.963-4.963a1.75 1.75 0 0 0 0-2.475l-.827-.826ZM11.72 3.22a.25.25 0 0 1 .354 0l.826.826a.25.25 0 0 1 0 .354L8.55 8.75l-1.186.339.338-1.186L11.72 3.22Z"/></svg>
                        </button>
                      </div>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            </div>
          </div>

          <%!-- Center: Paragraph editor --%>
          <div class="flex-1 min-w-0">
            <%= if @chapter do %>
              <%!-- Chapter header --%>
              <div class="flex items-center gap-2 mb-3 pb-2 border-b-2 border-primary/30" id={"chapter-#{@chapter.n}"}>
                <span class="text-primary font-mono text-sm font-bold">Ch. {@chapter.n}</span>
                <%= if @editing_chapter == @chapter.n do %>
                  <form phx-submit="rename_chapter" class="flex items-center gap-1 flex-1">
                    <input type="hidden" name="chapter" value={@chapter.n} />
                    <input type="text" name="title" value={@chapter.title} class="input input-bordered input-sm flex-1" autofocus />
                    <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    <button type="button" phx-click="cancel_edit_chapter" class="btn btn-ghost btn-sm">Cancel</button>
                  </form>
                <% else %>
                  <h2
                    class="text-lg font-semibold flex-1 cursor-pointer hover:text-primary transition-colors"
                    phx-click="edit_chapter_title"
                    phx-value-chapter={@chapter.n}
                    title="Click to rename"
                  >{@chapter.title}</h2>
                <% end %>
                <span class="text-base-content/30 text-xs">{length(@chapter.paragraphs)}p</span>
                <%= if @chapter.n > 1 do %>
                  <button
                    phx-click="remove_chapter_break"
                    phx-value-chapter={@chapter.n}
                    class="btn btn-ghost btn-xs text-base-content/40 hover:text-warning"
                    title="Remove this chapter break (merge with previous)"
                  >Merge up</button>
                <% end %>
              </div>

              <%!-- Paragraph list with scroll spy --%>
              <div id="paragraph-list" phx-hook="ScrollSpy" class="space-y-0">
                <div class="flex items-center justify-end mb-1">
                  <button phx-click="select_all_chapter" class="btn btn-ghost btn-xs text-base-content/40">Select all</button>
                </div>

                <%= for {para, idx} <- Enum.with_index(@chapter.paragraphs) do %>
                  <%!-- Between-paragraph zone: glue + chapter break --%>
                  <%= if idx > 0 do %>
                    <div class="group relative h-3 cursor-pointer hover:h-10 transition-all duration-150 flex items-center justify-center">
                      <div class="hidden group-hover:flex items-center gap-3 absolute inset-x-0 top-0 bottom-0 rounded justify-center">
                        <button
                          phx-click="glue_paragraphs"
                          phx-value-ref-id={para.ref_id}
                          class="btn btn-ghost btn-xs text-success border-dashed border-success/30 bg-success/10 hover:bg-success/20"
                          title="Merge with paragraph above"
                        >Glue</button>
                        <button
                          phx-click="insert_chapter_break"
                          phx-value-ref-id={para.ref_id}
                          class="btn btn-ghost btn-xs text-info border-dashed border-info/30 bg-info/10 hover:bg-info/20"
                        >+ Chapter break</button>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Paragraph --%>
                  <%= if @editing_paragraph == para.ref_id do %>
                    <div class="bg-base-200 rounded-lg p-3 my-1" data-ref-id={para.ref_id}>
                      <form phx-submit="save_paragraph">
                        <input type="hidden" name="ref_id" value={para.ref_id} />
                        <div class="flex gap-2 mb-2">
                          <div class="form-control flex-1">
                            <label class="label py-0"><span class="label-text text-xs">Speaker</span></label>
                            <input type="text" name="speaker" value={para.speaker || ""} placeholder="(none)" class="input input-bordered input-sm" />
                          </div>
                          <div class="form-control">
                            <label class="label py-0"><span class="label-text text-xs">Ref</span></label>
                            <span class="font-mono text-xs pt-2 text-base-content/40">{para.ref_id}</span>
                          </div>
                        </div>
                        <textarea
                          name="text"
                          rows={max(3, div(String.length(para.text), 80) + 1)}
                          class="textarea textarea-bordered w-full text-sm mb-2"
                        >{para.text}</textarea>
                        <div class="flex gap-1 justify-end">
                          <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">Cancel</button>
                          <button type="submit" class="btn btn-primary btn-xs">Save</button>
                        </div>
                      </form>
                    </div>
                  <% else %>
                    <div
                      data-ref-id={para.ref_id}
                      class={"group py-1.5 px-2 rounded transition-colors #{cond do
                        MapSet.member?(@selected_refs, para.ref_id) -> "bg-primary/5 ring-1 ring-primary/20"
                        @focused_ref == para.ref_id -> "bg-base-200"
                        true -> "hover:bg-base-200/50"
                      end}"}
                    >
                      <%!-- Line 1: metadata + actions --%>
                      <div class="flex items-center gap-2 mb-0.5">
                        <input
                          type="checkbox"
                          class="checkbox checkbox-xs checkbox-primary opacity-0 group-hover:opacity-100 transition-opacity"
                          checked={MapSet.member?(@selected_refs, para.ref_id)}
                          phx-click="toggle_select"
                          phx-value-ref-id={para.ref_id}
                          style={if MapSet.member?(@selected_refs, para.ref_id), do: "opacity: 1", else: ""}
                        />
                        <span class="font-mono text-xs text-base-content/30">{para.ref_id}</span>
                        <%!-- Speaker badge --%>
                        <%= if para.speaker do %>
                          <span class="badge badge-xs badge-outline">{para.speaker}</span>
                        <% else %>
                          <span class="badge badge-xs badge-ghost text-base-content/20">--</span>
                        <% end %>
                        <%!-- Speaker chips on hover --%>
                        <div class="hidden group-hover:flex gap-0.5">
                          <%= for speaker <- @speakers do %>
                            <button
                              phx-click="set_speaker"
                              phx-value-ref-id={para.ref_id}
                              phx-value-speaker={speaker}
                              class={"btn btn-xs px-1.5 min-h-0 h-5 #{if para.speaker == speaker, do: "btn-primary", else: "btn-ghost text-base-content/50"}"}
                              title={speaker}
                            >{speaker_initials(speaker)}</button>
                          <% end %>
                          <button
                            phx-click="set_speaker"
                            phx-value-ref-id={para.ref_id}
                            phx-value-speaker=""
                            class={"btn btn-xs px-1.5 min-h-0 h-5 #{if is_nil(para.speaker), do: "btn-primary", else: "btn-ghost text-base-content/30"}"}
                            title="Clear speaker"
                          >&times;</button>
                        </div>
                        <div class="flex-1"></div>
                        <div class="hidden group-hover:flex gap-1 shrink-0">
                          <button phx-click="edit_paragraph" phx-value-ref-id={para.ref_id} class="btn btn-ghost btn-sm px-2" title="Edit">
                            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4"><path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.05 7.475a.75.75 0 0 0-.186.312l-.9 3.15a.75.75 0 0 0 .926.926l3.15-.9a.75.75 0 0 0 .312-.186l4.963-4.963a1.75 1.75 0 0 0 0-2.475l-.827-.826ZM11.72 3.22a.25.25 0 0 1 .354 0l.826.826a.25.25 0 0 1 0 .354L8.55 8.75l-1.186.339.338-1.186L11.72 3.22Z"/></svg>
                          </button>
                          <button phx-click="delete_paragraph" phx-value-ref-id={para.ref_id} class="btn btn-ghost btn-sm px-2 text-error" title="Delete" data-confirm="Delete this paragraph?">
                            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4"><path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd"/></svg>
                          </button>
                        </div>
                      </div>
                      <%!-- Line 2: text content --%>
                      <p class="text-sm pl-6">{para.text}</p>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <%!-- Chapter nav footer --%>
              <div class="flex items-center justify-between mt-4 pt-3 border-t border-base-200">
                <%= if @chapter.n > 1 do %>
                  <button phx-click="select_chapter" phx-value-chapter={@chapter.n - 1} class="btn btn-ghost btn-sm">&larr; Prev</button>
                <% else %>
                  <div></div>
                <% end %>
                <%= if @chapter.n < Book.chapter_count(@book) do %>
                  <button phx-click="select_chapter" phx-value-chapter={@chapter.n + 1} class="btn btn-ghost btn-sm">Next &rarr;</button>
                <% end %>
              </div>
            <% else %>
              <p class="text-base-content/40">Select a chapter to edit.</p>
            <% end %>
          </div>

          <%!-- Right: JSON preview + diff --%>
          <div class="w-80 shrink-0 hidden xl:block">
            <div class="sticky top-2 space-y-3">
              <%!-- Change summary --%>
              <%= if @changes.has_changes do %>
                <div class="bg-warning/10 border border-warning/20 rounded-lg p-3">
                  <h4 class="font-semibold text-xs text-warning uppercase tracking-wide mb-2">Unsaved changes</h4>
                  <div class="space-y-1 text-xs">
                    <%= if @changes.ch_current != @changes.ch_saved do %>
                      <div class="flex justify-between">
                        <span>Chapters</span>
                        <span>
                          <span class="text-base-content/40">{@changes.ch_saved}</span>
                          <span>&rarr;</span>
                          <span class="font-semibold">{@changes.ch_current}</span>
                          <span class={if @changes.ch_current > @changes.ch_saved, do: "text-success", else: "text-error"}>
                            ({if @changes.ch_current > @changes.ch_saved, do: "+", else: ""}{@changes.ch_current - @changes.ch_saved})
                          </span>
                        </span>
                      </div>
                    <% end %>
                    <%= if @changes.p_current != @changes.p_saved do %>
                      <div class="flex justify-between">
                        <span>Paragraphs</span>
                        <span>
                          <span class="text-base-content/40">{@changes.p_saved}</span>
                          <span>&rarr;</span>
                          <span class="font-semibold">{@changes.p_current}</span>
                          <span class={if @changes.p_current > @changes.p_saved, do: "text-success", else: "text-error"}>
                            ({if @changes.p_current > @changes.p_saved, do: "+", else: ""}{@changes.p_current - @changes.p_saved})
                          </span>
                        </span>
                      </div>
                    <% end %>
                    <%= if @changes.added > 0 do %>
                      <div class="flex justify-between">
                        <span>New content</span>
                        <span class="text-success">+{@changes.added} blocks</span>
                      </div>
                    <% end %>
                    <%= if @changes.removed > 0 do %>
                      <div class="flex justify-between">
                        <span>Removed</span>
                        <span class="text-error">-{@changes.removed} blocks</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% else %>
                <div class="bg-success/10 border border-success/20 rounded-lg p-3">
                  <p class="text-xs text-success">All changes saved</p>
                </div>
              <% end %>

              <%!-- Speakers --%>
              <div>
                <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Speakers</h4>
                <div class="flex flex-wrap gap-1 mb-2">
                  <%= for speaker <- @speakers do %>
                    <div class="badge badge-sm gap-1">
                      <span>{speaker}</span>
                      <button
                        phx-click="remove_speaker_option"
                        phx-value-speaker={speaker}
                        class="text-base-content/40 hover:text-error"
                        title={"Remove #{speaker}"}
                      >&times;</button>
                    </div>
                  <% end %>
                </div>
                <form phx-submit="add_speaker_option" class="flex gap-1">
                  <input type="text" name="speaker" placeholder="Add speaker..." class="input input-bordered input-xs flex-1" />
                  <button type="submit" class="btn btn-ghost btn-xs">Add</button>
                </form>
              </div>

              <%!-- Chapter JSON --%>
              <%= if @ch_json do %>
                <div>
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Chapter</h4>
                  <pre class="bg-base-200 rounded-lg p-3 text-xs font-mono overflow-x-auto select-all whitespace-pre-wrap break-words">{@ch_json}</pre>
                </div>
              <% end %>

              <%!-- Focused paragraph JSON --%>
              <%= if @para_json do %>
                <div>
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Paragraph <span class="text-primary">{@focused_ref}</span></h4>
                  <pre class="bg-base-200 rounded-lg p-3 text-xs font-mono overflow-x-auto select-all whitespace-pre-wrap break-words">{@para_json}</pre>
                </div>
              <% else %>
                <div>
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Paragraph</h4>
                  <p class="text-xs text-base-content/30 italic">Scroll to focus a paragraph</p>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </IngestWeb.Layouts.app>
    """
  end
end
