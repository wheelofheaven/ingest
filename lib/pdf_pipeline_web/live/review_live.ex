defmodule PdfPipelineWeb.ReviewLive do
  use PdfPipelineWeb, :live_view

  alias PdfPipeline.Store.Job
  alias PdfPipeline.Schema.{Book, Chapter}
  alias PdfPipeline.Refiner.Strategy

  @impl true
  def mount(%{"job_id" => job_id}, _session, socket) do
    case Job.get(job_id) do
      {:ok, job} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PdfPipeline.PubSub, "jobs")
        end

        stats = if job.book, do: Strategy.refinement_stats(job.book), else: nil

        {:ok,
         socket
         |> assign(:job, job)
         |> assign(:stats, stats)
         |> assign(:selected_chapter, 1)
         |> assign(:page_title, "Review: #{job.metadata[:slug]}")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Job not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("select_chapter", %{"chapter" => chapter}, socket) do
    {:noreply, assign(socket, :selected_chapter, String.to_integer(chapter))}
  end

  @impl true
  def handle_info({:job_updated, %{id: id} = job}, socket) when id == socket.assigns.job.id do
    stats = if job.book, do: Strategy.refinement_stats(job.book), else: nil
    {:noreply, assign(socket, job: job, stats: stats)}
  end

  def handle_info({:job_updated, _}, socket), do: {:noreply, socket}

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
            <h1 class="text-2xl font-bold">Review: {@job.metadata[:slug]}</h1>
            <p class="text-base-content/60">
              Code: {@job.metadata[:code]} | Language: {@job.metadata[:primary_lang]}
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/review/#{@job.id}/edit"} class="btn btn-ghost">
              Edit
            </.link>
            <.link navigate={~p"/review/#{@job.id}/export"} class="btn btn-primary">
              Export
            </.link>
          </div>
        </div>

        <%!-- Stats --%>
        <%= if @stats do %>
          <div class="stats shadow w-full">
            <div class="stat">
              <div class="stat-title">Chapters</div>
              <div class="stat-value">{Book.chapter_count(@job.book)}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Paragraphs</div>
              <div class="stat-value">{@stats.total}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Confidence</div>
              <div class="stat-value">{@stats.percentage_clear}%</div>
              <div class="stat-desc">{@stats.ambiguous} need review</div>
            </div>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <%!-- Chapter Navigation --%>
          <div class="lg:col-span-1">
            <div class="card bg-base-200">
              <div class="card-body p-4">
                <h3 class="font-semibold mb-2">Chapters</h3>
                <%= if @job.book do %>
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
                          <span class="badge badge-sm badge-ghost">{length(ch.paragraphs)}</span>
                        </button>
                      </li>
                    <% end %>
                  </ul>
                <% else %>
                  <p class="text-sm text-base-content/40">No chapters parsed yet.</p>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Content Panel --%>
          <div class="lg:col-span-3">
            <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
              <%!-- OCR Output --%>
              <div class="card bg-base-200">
                <div class="card-body p-4">
                  <h3 class="font-semibold mb-2">OCR Output</h3>
                  <div class="bg-base-100 rounded-lg p-4 max-h-[600px] overflow-y-auto">
                    <%= if @job.ocr_text do %>
                      <pre class="text-sm whitespace-pre-wrap font-mono">{@job.ocr_text}</pre>
                    <% else %>
                      <p class="text-base-content/40">No OCR output available.</p>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Structured Output --%>
              <div class="card bg-base-200">
                <div class="card-body p-4">
                  <h3 class="font-semibold mb-2">
                    Structured Output
                    <%= if @chapter do %>
                      — {Chapter.paragraph_count(@chapter)} paragraphs
                    <% end %>
                  </h3>
                  <div class="space-y-2 max-h-[600px] overflow-y-auto">
                    <%= if @chapter do %>
                      <%= for para <- @chapter.paragraphs do %>
                        <div class={"card bg-base-100 border-l-4 #{confidence_class(para.confidence)}"}>
                          <div class="card-body p-3">
                            <div class="flex items-center justify-between">
                              <span class="font-mono text-xs text-base-content/40">{para.ref_id}</span>
                              <%= if para.speaker do %>
                                <span class="badge badge-sm badge-outline">{para.speaker}</span>
                              <% end %>
                            </div>
                            <p class="text-sm">{para.text}</p>
                          </div>
                        </div>
                      <% end %>
                    <% else %>
                      <p class="text-base-content/40">Select a chapter to view.</p>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PdfPipelineWeb.Layouts.app>
    """
  end
end
