defmodule PdfPipelineWeb.EditorLive do
  use PdfPipelineWeb, :live_view

  alias PdfPipeline.Store.Job
  alias PdfPipeline.Schema.{Book, Chapter}
  alias PdfPipeline.Refiner.LlmClient

  @impl true
  def mount(%{"job_id" => job_id}, _session, socket) do
    case Job.get(job_id) do
      {:ok, %{book: nil}} ->
        {:ok,
         socket
         |> put_flash(:error, "Book not yet parsed")
         |> push_navigate(to: ~p"/review/#{job_id}")}

      {:ok, job} ->
        {:ok,
         socket
         |> assign(:job, job)
         |> assign(:selected_chapter, 1)
         |> assign(:editing_paragraph, nil)
         |> assign(:page_title, "Edit: #{job.metadata[:slug]}")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Job not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("select_chapter", %{"chapter" => chapter}, socket) do
    {:noreply, assign(socket, selected_chapter: String.to_integer(chapter), editing_paragraph: nil)}
  end

  @impl true
  def handle_event("edit_paragraph", %{"ref-id" => ref_id}, socket) do
    {:noreply, assign(socket, :editing_paragraph, ref_id)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_paragraph, nil)}
  end

  @impl true
  def handle_event("save_paragraph", %{"ref_id" => ref_id, "text" => text, "speaker" => speaker}, socket) do
    job = socket.assigns.job
    book = job.book

    speaker = if speaker == "", do: nil, else: speaker

    updated_chapters =
      Enum.map(book.chapters, fn chapter ->
        updated_paragraphs =
          Enum.map(chapter.paragraphs, fn para ->
            if para.ref_id == ref_id do
              %{para | text: text, speaker: speaker, confidence: 1.0}
            else
              para
            end
          end)

        %{chapter | paragraphs: updated_paragraphs}
      end)

    updated_book = %{book | chapters: updated_chapters}
    {:ok, updated_job} = Job.update(job.id, %{book: updated_book})

    {:noreply,
     socket
     |> assign(:job, updated_job)
     |> assign(:editing_paragraph, nil)
     |> put_flash(:info, "Paragraph #{ref_id} updated")}
  end

  @impl true
  def handle_event("refine_paragraph", %{"ref-id" => ref_id}, socket) do
    job = socket.assigns.job
    chapter_n = socket.assigns.selected_chapter

    chapter = Enum.find(job.book.chapters, &(&1.n == chapter_n))
    para = Enum.find(chapter.paragraphs, &(&1.ref_id == ref_id))

    if para do
      context = %{
        book_title: Map.get(job.book.titles, job.book.primary_lang, job.book.slug),
        known_speakers: extract_known_speakers(job.book)
      }

      # Run LLM refinement for this specific paragraph
      Task.start(fn ->
        refined = LlmClient.refine_batch([para], context)
        send(self(), {:refinement_result, ref_id, List.first(refined)})
      end)

      {:noreply, put_flash(socket, :info, "Sending paragraph to LLM for refinement...")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("merge_with_next", %{"ref-id" => ref_id}, socket) do
    job = socket.assigns.job
    book = job.book
    chapter_n = socket.assigns.selected_chapter

    updated_chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == chapter_n do
          merge_paragraphs(chapter, ref_id)
        else
          chapter
        end
      end)

    updated_book = %{book | chapters: updated_chapters} |> Book.assign_ref_ids()
    {:ok, updated_job} = Job.update(job.id, %{book: updated_book})

    {:noreply,
     socket
     |> assign(:job, updated_job)
     |> put_flash(:info, "Paragraphs merged")}
  end

  @impl true
  def handle_info({:refinement_result, ref_id, refined_para}, socket) do
    if refined_para do
      job = socket.assigns.job
      book = job.book

      updated_chapters =
        Enum.map(book.chapters, fn chapter ->
          updated_paragraphs =
            Enum.map(chapter.paragraphs, fn para ->
              if para.ref_id == ref_id, do: refined_para, else: para
            end)

          %{chapter | paragraphs: updated_paragraphs}
        end)

      updated_book = %{book | chapters: updated_chapters}
      {:ok, updated_job} = Job.update(job.id, %{book: updated_book})

      {:noreply,
       socket
       |> assign(:job, updated_job)
       |> put_flash(:info, "Paragraph #{ref_id} refined by LLM")}
    else
      {:noreply, put_flash(socket, :error, "Refinement failed for #{ref_id}")}
    end
  end

  def handle_info({:job_updated, _}, socket), do: {:noreply, socket}

  defp merge_paragraphs(chapter, ref_id) do
    paragraphs = chapter.paragraphs
    idx = Enum.find_index(paragraphs, &(&1.ref_id == ref_id))

    if idx && idx < length(paragraphs) - 1 do
      current = Enum.at(paragraphs, idx)
      next = Enum.at(paragraphs, idx + 1)

      merged = %{current | text: current.text <> "\n\n" <> next.text}

      new_paragraphs =
        paragraphs
        |> List.delete_at(idx + 1)
        |> List.replace_at(idx, merged)
        |> Enum.with_index(1)
        |> Enum.map(fn {p, i} -> %{p | n: i} end)

      %{chapter | paragraphs: new_paragraphs}
    else
      chapter
    end
  end

  defp extract_known_speakers(book) do
    book.chapters
    |> Enum.flat_map(& &1.paragraphs)
    |> Enum.map(& &1.speaker)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp get_chapter(job, n) do
    if job.book do
      Enum.find(job.book.chapters, &(&1.n == n))
    end
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
    assigns = assign(assigns, :chapter, get_chapter(assigns.job, assigns.selected_chapter))

    ~H"""
    <PdfPipelineWeb.Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">Edit: {@job.metadata[:slug]}</h1>
            <p class="text-base-content/60">
              Edit paragraphs, fix speakers, merge/split content.
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/review/#{@job.id}"} class="btn btn-ghost">
              Back to Review
            </.link>
            <.link navigate={~p"/review/#{@job.id}/export"} class="btn btn-primary">
              Export
            </.link>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <%!-- Chapter Navigation --%>
          <div class="lg:col-span-1">
            <div class="card bg-base-200">
              <div class="card-body p-4">
                <h3 class="font-semibold mb-2">Chapters</h3>
                <ul class="menu menu-sm bg-base-100 rounded-box">
                  <%= for ch <- @job.book.chapters do %>
                    <li>
                      <button
                        phx-click="select_chapter"
                        phx-value-chapter={ch.n}
                        class={if @selected_chapter == ch.n, do: "active", else: ""}
                      >
                        <span class="font-mono text-xs">{ch.n}.</span>
                        {ch.title}
                      </button>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
          </div>

          <%!-- Editor Panel --%>
          <div class="lg:col-span-3 space-y-3">
            <%= if @chapter do %>
              <h2 class="text-lg font-semibold">
                Chapter {@chapter.n}: {@chapter.title}
                <span class="text-sm font-normal text-base-content/40">
                  ({Chapter.paragraph_count(@chapter)} paragraphs)
                </span>
              </h2>

              <%= for para <- @chapter.paragraphs do %>
                <div class={"card bg-base-100 border-l-4 #{confidence_class(para.confidence)}"}>
                  <div class="card-body p-4">
                    <%= if @editing_paragraph == para.ref_id do %>
                      <%!-- Edit Mode --%>
                      <form phx-submit="save_paragraph">
                        <input type="hidden" name="ref_id" value={para.ref_id} />
                        <div class="form-control mb-2">
                          <label class="label"><span class="label-text">Speaker</span></label>
                          <input
                            type="text"
                            name="speaker"
                            value={para.speaker || ""}
                            placeholder="Narrator"
                            class="input input-bordered input-sm w-full"
                          />
                        </div>
                        <div class="form-control mb-2">
                          <label class="label"><span class="label-text">Text</span></label>
                          <textarea
                            name="text"
                            rows="4"
                            class="textarea textarea-bordered w-full"
                          >{para.text}</textarea>
                        </div>
                        <div class="flex gap-2 justify-end">
                          <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
                          <button type="submit" class="btn btn-primary btn-sm">Save</button>
                        </div>
                      </form>
                    <% else %>
                      <%!-- View Mode --%>
                      <div class="flex items-center justify-between mb-1">
                        <div class="flex items-center gap-2">
                          <span class="font-mono text-xs text-base-content/40">{para.ref_id}</span>
                          <%= if para.speaker do %>
                            <span class="badge badge-sm badge-outline">{para.speaker}</span>
                          <% else %>
                            <span class="badge badge-sm badge-error badge-outline">no speaker</span>
                          <% end %>
                          <span class="text-xs text-base-content/30">
                            conf: {Float.round(para.confidence, 2)}
                          </span>
                        </div>
                        <div class="flex gap-1">
                          <button
                            phx-click="edit_paragraph"
                            phx-value-ref-id={para.ref_id}
                            class="btn btn-ghost btn-xs"
                          >
                            Edit
                          </button>
                          <button
                            phx-click="merge_with_next"
                            phx-value-ref-id={para.ref_id}
                            class="btn btn-ghost btn-xs"
                          >
                            Merge
                          </button>
                          <button
                            phx-click="refine_paragraph"
                            phx-value-ref-id={para.ref_id}
                            class="btn btn-ghost btn-xs"
                          >
                            LLM
                          </button>
                        </div>
                      </div>
                      <p class="text-sm">{para.text}</p>
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
    </PdfPipelineWeb.Layouts.app>
    """
  end
end
