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
      {:error, _} -> {:error, "No book.json found in _work/#{slug}/"}
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

  # -- Single paragraph editing --

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
     |> assign(:dirty, true)
     |> put_flash(:info, "Paragraph #{ref_id} updated")}
  end

  # -- Delete single paragraph --

  def handle_event("delete_paragraph", %{"ref-id" => ref_id}, socket) do
    book = delete_paragraphs(socket.assigns.book, [ref_id])

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> assign(:repeated_patterns, detect_repeated_patterns(book))
     |> put_flash(:info, "Paragraph deleted")}
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

  # -- Repeated pattern detection & removal --

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
     |> put_flash(:info, "Removed #{length(matching_refs)} occurrences of repeated text")}
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

  # -- Split paragraph --

  def handle_event("split_paragraph", %{"ref-id" => ref_id, "position" => pos_str}, socket) do
    position = String.to_integer(pos_str)
    book = split_paragraph_at(socket.assigns.book, ref_id, position)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> put_flash(:info, "Paragraph split")}
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
     |> assign(:dirty, true)
     |> put_flash(:info, "Paragraphs merged")}
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
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter #{n} renamed")}
  end

  def handle_event("edit_chapter_title", %{"chapter" => n_str}, socket) do
    {:noreply, assign(socket, :editing_chapter, String.to_integer(n_str))}
  end

  def handle_event("cancel_edit_chapter", _params, socket) do
    {:noreply, assign(socket, :editing_chapter, nil)}
  end

  def handle_event("split_chapter_here", %{"ref-id" => ref_id}, socket) do
    book = socket.assigns.book
    chapter_n = socket.assigns.selected_chapter
    book = split_chapter_at_paragraph(book, chapter_n, ref_id)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter split at paragraph #{ref_id}")}
  end

  def handle_event("merge_chapter_with_next", %{"chapter" => n_str}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book
    book = merge_chapters(book, n)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapters merged")}
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

  def handle_event("add_chapter", _params, socket) do
    book = socket.assigns.book
    new_n = length(book.chapters) + 1

    new_chapter = Chapter.new(%{n: new_n, title: "New Chapter", paragraphs: []})
    book = %{book | chapters: book.chapters ++ [new_chapter]} |> Book.assign_ref_ids()

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_chapter, new_n)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter #{new_n} added")}
  end

  # -- Save to work directory --

  def handle_event("save_to_disk", _params, socket) do
    book = socket.assigns.book
    slug = socket.assigns.slug
    json = Book.to_json(book)
    encoded = Jason.encode!(json, pretty: true)
    {:ok, path} = WorkDir.write_artifact(slug, "book.json", encoded)

    # Also update the job if we have one
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

  defp split_paragraph_at(book, ref_id, position) do
    chapters =
      Enum.map(book.chapters, fn chapter ->
        case Enum.find_index(chapter.paragraphs, &(&1.ref_id == ref_id)) do
          nil ->
            chapter

          idx ->
            para = Enum.at(chapter.paragraphs, idx)
            {before_text, after_text} = String.split_at(para.text, position)

            first = %{para | text: String.trim(before_text)}
            second = %{para | text: String.trim(after_text), n: para.n + 1, ref_id: nil}

            paragraphs =
              chapter.paragraphs
              |> List.replace_at(idx, first)
              |> List.insert_at(idx + 1, second)

            %{chapter | paragraphs: paragraphs}
        end
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

              # Use the text of the split paragraph as hint for the new chapter title
              first_para_text = List.first(after_paras)
              new_title =
                if first_para_text,
                  do: String.slice(first_para_text.text, 0, 60) |> String.trim(),
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

  defp confidence_class(confidence) do
    cond do
      confidence >= 0.8 -> "border-l-success"
      confidence >= 0.5 -> "border-l-warning"
      true -> "border-l-error"
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :chapter, get_chapter(assigns.book, assigns.selected_chapter))
    selected_count = MapSet.size(assigns.selected_refs)
    assigns = assign(assigns, :selected_count, selected_count)

    ~H"""
    <IngestWeb.Layouts.app flash={@flash}>
      <div class="space-y-4">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">Edit: {@slug}</h1>
            <p class="text-base-content/60 text-sm">
              {Book.chapter_count(@book)} chapters, {Book.paragraph_count(@book)} paragraphs
            </p>
          </div>
          <div class="flex gap-2 items-center">
            <%= if @dirty do %>
              <span class="badge badge-warning badge-sm">unsaved</span>
            <% end %>
            <button phx-click="save_to_disk" class={"btn btn-sm #{if @dirty, do: "btn-warning", else: "btn-ghost"}"}>
              Save
            </button>
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
              Dashboard
            </.link>
          </div>
        </div>

        <%!-- Repeated Patterns Alert --%>
        <%= if @repeated_patterns != [] do %>
          <div class="alert shadow-sm">
            <div class="flex-1">
              <button phx-click="toggle_patterns" class="flex items-center gap-2 w-full text-left">
                <span class="font-semibold">
                  {length(@repeated_patterns)} repeated text patterns detected
                </span>
                <span class="text-xs text-base-content/50">
                  (likely page headers/footers — click to review)
                </span>
                <span class="ml-auto text-xs">{if @show_patterns, do: "Hide", else: "Show"}</span>
              </button>

              <%= if @show_patterns do %>
                <div class="mt-3 space-y-2">
                  <%= for pattern <- @repeated_patterns do %>
                    <div class="flex items-center gap-2 bg-base-200 rounded-lg p-2">
                      <div class="flex-1 min-w-0">
                        <p class="text-sm font-mono truncate">{pattern.short}<%= if String.length(pattern.text) > 80, do: "..." %></p>
                        <p class="text-xs text-base-content/40">{pattern.count} occurrences</p>
                      </div>
                      <button
                        phx-click="select_pattern"
                        phx-value-pattern={pattern.text}
                        class="btn btn-ghost btn-xs"
                      >
                        Select
                      </button>
                      <button
                        phx-click="remove_pattern"
                        phx-value-pattern={pattern.text}
                        class="btn btn-error btn-xs"
                        data-confirm={"Remove all #{pattern.count} occurrences of this text?"}
                      >
                        Remove all
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Bulk Actions Bar --%>
        <%= if @selected_count > 0 do %>
          <div class="sticky top-0 z-10 bg-base-300 rounded-lg p-3 flex items-center gap-3 shadow-lg">
            <span class="font-semibold text-sm">{@selected_count} selected</span>
            <button phx-click="select_none" class="btn btn-ghost btn-xs">Clear</button>
            <div class="divider divider-horizontal mx-0"></div>
            <button
              phx-click="delete_selected"
              class="btn btn-error btn-sm"
              data-confirm={"Delete #{@selected_count} selected paragraphs?"}
            >
              Delete selected
            </button>
            <form phx-submit="set_speaker_selected" class="flex items-center gap-2">
              <input
                type="text"
                name="speaker"
                placeholder="Set speaker..."
                class="input input-bordered input-sm w-40"
              />
              <button type="submit" class="btn btn-sm btn-ghost">Apply</button>
            </form>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-5 gap-4">
          <%!-- Chapter Navigation --%>
          <div class="lg:col-span-1">
            <div class="card bg-base-200">
              <div class="card-body p-3">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="font-semibold text-sm">Chapters</h3>
                  <button phx-click="add_chapter" class="btn btn-ghost btn-xs">+ Add</button>
                </div>
                <ul class="menu menu-xs bg-base-100 rounded-box">
                  <%= for ch <- @book.chapters do %>
                    <li>
                      <%= if @editing_chapter == ch.n do %>
                        <form phx-submit="rename_chapter" class="p-1">
                          <input type="hidden" name="chapter" value={ch.n} />
                          <input
                            type="text"
                            name="title"
                            value={ch.title}
                            class="input input-bordered input-xs w-full mb-1"
                            autofocus
                          />
                          <div class="flex gap-1">
                            <button type="submit" class="btn btn-primary btn-xs flex-1">Save</button>
                            <button type="button" phx-click="cancel_edit_chapter" class="btn btn-ghost btn-xs">X</button>
                          </div>
                        </form>
                      <% else %>
                        <div class="flex items-center group">
                          <button
                            phx-click="select_chapter"
                            phx-value-chapter={ch.n}
                            class={"flex-1 text-left #{if @selected_chapter == ch.n, do: "active", else: ""}"}
                          >
                            <span class="font-mono text-xs">{ch.n}.</span>
                            <span class="truncate">{ch.title}</span>
                            <span class="badge badge-xs badge-ghost">{length(ch.paragraphs)}</span>
                          </button>
                          <div class="hidden group-hover:flex gap-0.5 ml-1">
                            <button
                              phx-click="edit_chapter_title"
                              phx-value-chapter={ch.n}
                              class="btn btn-ghost btn-xs px-1"
                              title="Rename"
                            >R</button>
                            <button
                              phx-click="merge_chapter_with_next"
                              phx-value-chapter={ch.n}
                              class="btn btn-ghost btn-xs px-1"
                              title="Merge with next"
                            >M</button>
                            <button
                              phx-click="delete_chapter"
                              phx-value-chapter={ch.n}
                              class="btn btn-ghost btn-xs px-1 text-error"
                              title="Delete chapter"
                              data-confirm={"Delete chapter #{ch.n}: #{ch.title}?"}
                            >X</button>
                          </div>
                        </div>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
          </div>

          <%!-- Editor Panel --%>
          <div class="lg:col-span-4 space-y-2">
            <%= if @chapter do %>
              <div class="flex items-center justify-between mb-2">
                <h2 class="text-lg font-semibold">
                  Chapter {@chapter.n}: {@chapter.title}
                  <span class="text-sm font-normal text-base-content/40">
                    ({Chapter.paragraph_count(@chapter)} paragraphs)
                  </span>
                </h2>
                <div class="flex gap-1">
                  <button phx-click="select_all_chapter" class="btn btn-ghost btn-xs">
                    Select all
                  </button>
                  <%= if @selected_count > 0 do %>
                    <button phx-click="select_none" class="btn btn-ghost btn-xs">
                      Clear
                    </button>
                  <% end %>
                </div>
              </div>

              <%= for para <- @chapter.paragraphs do %>
                <div class={"card bg-base-100 border-l-4 #{confidence_class(para.confidence)} #{if MapSet.member?(@selected_refs, para.ref_id), do: "ring-2 ring-primary", else: ""}"}>
                  <div class="card-body p-3">
                    <%= if @editing_paragraph == para.ref_id do %>
                      <%!-- Edit Mode --%>
                      <form phx-submit="save_paragraph">
                        <input type="hidden" name="ref_id" value={para.ref_id} />
                        <div class="grid grid-cols-2 gap-2 mb-2">
                          <div class="form-control">
                            <label class="label py-0"><span class="label-text text-xs">Speaker</span></label>
                            <input
                              type="text"
                              name="speaker"
                              value={para.speaker || ""}
                              placeholder="(none)"
                              class="input input-bordered input-sm w-full"
                            />
                          </div>
                          <div class="form-control">
                            <label class="label py-0"><span class="label-text text-xs">Split at position</span></label>
                            <div class="flex gap-1">
                              <input type="number" id={"split-pos-#{para.ref_id}"} min="1" max={String.length(para.text) - 1} value={div(String.length(para.text), 2)} class="input input-bordered input-sm flex-1" />
                              <button
                                type="button"
                                phx-click="split_paragraph"
                                phx-value-ref-id={para.ref_id}
                                phx-value-position={div(String.length(para.text), 2)}
                                class="btn btn-ghost btn-sm"
                              >
                                Split
                              </button>
                            </div>
                          </div>
                        </div>
                        <div class="form-control mb-2">
                          <textarea
                            name="text"
                            rows={max(3, div(String.length(para.text), 80) + 1)}
                            class="textarea textarea-bordered w-full text-sm"
                          >{para.text}</textarea>
                        </div>
                        <div class="flex gap-2 justify-end">
                          <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">Cancel</button>
                          <button type="submit" class="btn btn-primary btn-xs">Save</button>
                        </div>
                      </form>
                    <% else %>
                      <%!-- View Mode --%>
                      <div class="flex items-center gap-2 mb-1">
                        <input
                          type="checkbox"
                          class="checkbox checkbox-xs checkbox-primary"
                          checked={MapSet.member?(@selected_refs, para.ref_id)}
                          phx-click="toggle_select"
                          phx-value-ref-id={para.ref_id}
                        />
                        <span class="font-mono text-xs text-base-content/40">{para.ref_id}</span>
                        <%= if para.speaker do %>
                          <span class="badge badge-xs badge-outline">{para.speaker}</span>
                        <% end %>
                        <span class="text-xs text-base-content/20">
                          {String.length(para.text)} chars
                        </span>
                        <div class="flex-1"></div>
                        <div class="flex gap-0.5">
                          <button phx-click="edit_paragraph" phx-value-ref-id={para.ref_id} class="btn btn-ghost btn-xs">Edit</button>
                          <button phx-click="merge_with_next" phx-value-ref-id={para.ref_id} class="btn btn-ghost btn-xs">Merge</button>
                          <button
                            phx-click="split_chapter_here"
                            phx-value-ref-id={para.ref_id}
                            class="btn btn-ghost btn-xs text-info"
                            title="Start a new chapter from this paragraph"
                          >
                            Ch.Split
                          </button>
                          <button
                            phx-click="delete_paragraph"
                            phx-value-ref-id={para.ref_id}
                            class="btn btn-ghost btn-xs text-error"
                            data-confirm="Delete this paragraph?"
                          >
                            Delete
                          </button>
                        </div>
                      </div>
                      <p class="text-sm pl-6">{para.text}</p>
                    <% end %>
                  </div>
                </div>
              <% end %>
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
