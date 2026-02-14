defmodule IngestWeb.EditorLive do
  use IngestWeb, :live_view

  alias Ingest.Store.Job
  alias Ingest.Schema.{Book, Chapter}
  alias Ingest.Stages.{WorkDir, Normalize}

  @impl true
  def mount(params, _session, socket) do
    case load_book(params) do
      {:ok, book, slug, source} ->
        repeated = detect_repeated_patterns(book)

        {:ok,
         socket
         |> assign(:book, book)
         |> assign(:slug, slug)
         |> assign(:source, source)
         |> assign(:selected_chapter, 1)
         |> assign(:editing_paragraph, nil)
         |> assign(:editing_chapter, nil)
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

  # -- Chapter navigation --

  @impl true
  def handle_event("select_chapter", %{"chapter" => chapter}, socket) do
    {:noreply,
     socket
     |> assign(:selected_chapter, String.to_integer(chapter))
     |> assign(:editing_paragraph, nil)
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

  # -- Chapter break insertion (the key interaction) --

  def handle_event("insert_chapter_break", %{"ref-id" => ref_id}, socket) do
    book = socket.assigns.book
    chapter_n = socket.assigns.selected_chapter
    book = split_chapter_at_paragraph(book, chapter_n, ref_id)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter break inserted")}
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
      # Merge this chapter into the previous one
      book = merge_chapters(book, n - 1)

      {:noreply,
       socket
       |> assign(:book, book)
       |> assign(:selected_chapter, n - 1)
       |> assign(:dirty, true)
       |> put_flash(:info, "Chapter break removed — merged with previous")}
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
     |> assign(:dirty, false)
     |> put_flash(:info, "Saved to #{path}")}
  end

  # -- Private helpers --

  defp get_chapter(book, n) do
    Enum.find(book.chapters, &(&1.n == n))
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

  # -- Render --

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :chapter, get_chapter(assigns.book, assigns.selected_chapter))
    selected_count = MapSet.size(assigns.selected_refs)
    assigns = assign(assigns, :selected_count, selected_count)

    ~H"""
    <IngestWeb.Layouts.app flash={@flash}>
      <div class="space-y-3">
        <%!-- Header bar --%>
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

        <%!-- Repeated patterns (collapsible) --%>
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
                    <button
                      phx-click="remove_pattern"
                      phx-value-pattern={pattern.text}
                      class="btn btn-error btn-xs"
                      data-confirm={"Remove all #{pattern.count} occurrences?"}
                    >Remove</button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Bulk actions bar (sticky) --%>
        <%= if @selected_count > 0 do %>
          <div class="sticky top-0 z-10 bg-base-300 rounded-lg p-2 flex items-center gap-3 shadow-lg text-sm">
            <span class="font-semibold">{@selected_count} selected</span>
            <button phx-click="select_none" class="btn btn-ghost btn-xs">Clear</button>
            <div class="divider divider-horizontal mx-0"></div>
            <button
              phx-click="delete_selected"
              class="btn btn-error btn-xs"
              data-confirm={"Delete #{@selected_count} paragraphs?"}
            >Delete</button>
            <form phx-submit="set_speaker_selected" class="flex items-center gap-1">
              <input type="text" name="speaker" placeholder="Speaker..." class="input input-bordered input-xs w-32" />
              <button type="submit" class="btn btn-xs btn-ghost">Set</button>
            </form>
          </div>
        <% end %>

        <div class="flex gap-4">
          <%!-- Chapter sidebar (navigation) --%>
          <div class="w-56 shrink-0">
            <div class="sticky top-2">
              <h3 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-2">Chapters</h3>
              <ul class="space-y-0.5">
                <%= for ch <- @book.chapters do %>
                  <li>
                    <button
                      phx-click="select_chapter"
                      phx-value-chapter={ch.n}
                      class={"flex items-center gap-1.5 w-full text-left px-2 py-1 rounded text-sm hover:bg-base-200 transition-colors #{if @selected_chapter == ch.n, do: "bg-base-200 font-medium", else: ""}"}
                    >
                      <span class="text-base-content/30 font-mono text-xs w-5 text-right shrink-0">{ch.n}</span>
                      <span class="truncate flex-1">{ch.title}</span>
                      <span class="text-base-content/30 text-xs">{length(ch.paragraphs)}</span>
                    </button>
                  </li>
                <% end %>
              </ul>
            </div>
          </div>

          <%!-- Main content area --%>
          <div class="flex-1 min-w-0">
            <%= if @chapter do %>
              <%!-- Chapter divider / header --%>
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
                <span class="text-base-content/30 text-xs">{length(@chapter.paragraphs)} paragraphs</span>
                <%= if @chapter.n > 1 do %>
                  <button
                    phx-click="remove_chapter_break"
                    phx-value-chapter={@chapter.n}
                    class="btn btn-ghost btn-xs text-base-content/40 hover:text-warning"
                    title="Remove this chapter break (merge with previous)"
                  >Merge up</button>
                <% end %>
              </div>

              <%!-- Paragraph list with interactive gaps --%>
              <div class="space-y-0">
                <div class="flex items-center justify-end mb-1">
                  <button phx-click="select_all_chapter" class="btn btn-ghost btn-xs text-base-content/40">Select all</button>
                </div>

                <%= for {para, idx} <- Enum.with_index(@chapter.paragraphs) do %>
                  <%!-- Chapter break insertion gap (between paragraphs) --%>
                  <%= if idx > 0 do %>
                    <div
                      class="group relative h-1 -my-0.5 cursor-pointer hover:h-8 transition-all duration-150 flex items-center justify-center"
                      phx-click="insert_chapter_break"
                      phx-value-ref-id={para.ref_id}
                    >
                      <div class="hidden group-hover:flex items-center gap-2 absolute inset-x-0 top-0 bottom-0 bg-info/10 rounded border border-dashed border-info/30 justify-center">
                        <span class="text-info text-xs font-medium">+ Insert chapter break here</span>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Paragraph row --%>
                  <%= if @editing_paragraph == para.ref_id do %>
                    <%!-- Editing mode --%>
                    <div class="bg-base-200 rounded-lg p-3 my-1">
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
                    <%!-- View mode — compact row --%>
                    <div class={"group flex items-start gap-2 py-1.5 px-2 rounded hover:bg-base-200/50 transition-colors #{if MapSet.member?(@selected_refs, para.ref_id), do: "bg-primary/5 ring-1 ring-primary/20", else: ""}"}>
                      <%!-- Checkbox --%>
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs checkbox-primary mt-1 opacity-0 group-hover:opacity-100 transition-opacity"
                        checked={MapSet.member?(@selected_refs, para.ref_id)}
                        phx-click="toggle_select"
                        phx-value-ref-id={para.ref_id}
                        style={if MapSet.member?(@selected_refs, para.ref_id), do: "opacity: 1", else: ""}
                      />

                      <%!-- Ref ID --%>
                      <span class="font-mono text-xs text-base-content/20 w-16 shrink-0 pt-0.5 text-right">{para.ref_id}</span>

                      <%!-- Speaker badge --%>
                      <%= if para.speaker do %>
                        <span class="badge badge-xs badge-outline shrink-0 mt-0.5">{para.speaker}</span>
                      <% end %>

                      <%!-- Text --%>
                      <p class="text-sm flex-1 min-w-0">{para.text}</p>

                      <%!-- Hover actions --%>
                      <div class="hidden group-hover:flex gap-0.5 shrink-0">
                        <button phx-click="edit_paragraph" phx-value-ref-id={para.ref_id} class="btn btn-ghost btn-xs px-1" title="Edit">
                          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3"><path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.05 7.475a.75.75 0 0 0-.186.312l-.9 3.15a.75.75 0 0 0 .926.926l3.15-.9a.75.75 0 0 0 .312-.186l4.963-4.963a1.75 1.75 0 0 0 0-2.475l-.827-.826ZM11.72 3.22a.25.25 0 0 1 .354 0l.826.826a.25.25 0 0 1 0 .354L8.55 8.75l-1.186.339.338-1.186L11.72 3.22Z"/></svg>
                        </button>
                        <button phx-click="merge_with_next" phx-value-ref-id={para.ref_id} class="btn btn-ghost btn-xs px-1" title="Merge with next">
                          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3"><path d="M2 7.75a.75.75 0 0 1 .75-.75h10.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 7.75Z"/></svg>
                        </button>
                        <button
                          phx-click="delete_paragraph"
                          phx-value-ref-id={para.ref_id}
                          class="btn btn-ghost btn-xs px-1 text-error"
                          title="Delete"
                          data-confirm="Delete this paragraph?"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3"><path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd"/></svg>
                        </button>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <%!-- Chapter navigation footer --%>
              <div class="flex items-center justify-between mt-4 pt-3 border-t border-base-200">
                <%= if @chapter.n > 1 do %>
                  <button phx-click="select_chapter" phx-value-chapter={@chapter.n - 1} class="btn btn-ghost btn-sm">
                    &larr; Previous chapter
                  </button>
                <% else %>
                  <div></div>
                <% end %>
                <%= if @chapter.n < Book.chapter_count(@book) do %>
                  <button phx-click="select_chapter" phx-value-chapter={@chapter.n + 1} class="btn btn-ghost btn-sm">
                    Next chapter &rarr;
                  </button>
                <% end %>
              </div>
            <% else %>
              <p class="text-base-content/40">Select a chapter to edit.</p>
            <% end %>
          </div>
        </div>
      </div>
    </IngestWeb.Layouts.app>
    """
  end
end
