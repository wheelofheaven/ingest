defmodule PdfPipelineWeb.ExportLive do
  use PdfPipelineWeb, :live_view

  alias PdfPipeline.Store.Job
  alias PdfPipeline.Schema.{Book, Validator}
  alias PdfPipeline.Export.DataLibrary
  alias PdfPipeline.Refiner.Strategy

  @impl true
  def mount(%{"job_id" => job_id}, _session, socket) do
    case Job.get(job_id) do
      {:ok, %{book: nil}} ->
        {:ok,
         socket
         |> put_flash(:error, "Book not yet parsed")
         |> push_navigate(to: ~p"/review/#{job_id}")}

      {:ok, job} ->
        {:ok, preview_json} = DataLibrary.preview(job.book)
        encoded = Jason.encode!(preview_json, pretty: true)
        validation = Validator.validate_book(preview_json)
        stats = Strategy.refinement_stats(job.book)

        {:ok,
         socket
         |> assign(:job, job)
         |> assign(:preview_json, encoded)
         |> assign(:validation, validation)
         |> assign(:stats, stats)
         |> assign(:exported, false)
         |> assign(:export_path, nil)
         |> assign(:page_title, "Export: #{job.metadata[:slug]}")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Job not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("export", _params, socket) do
    job = socket.assigns.job

    case DataLibrary.export(job.book) do
      {:ok, path} ->
        Job.update(job.id, %{output_path: path})

        {:noreply,
         socket
         |> assign(:exported, true)
         |> assign(:export_path, path)
         |> put_flash(:info, "Exported to #{path}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Export failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("download", _params, socket) do
    {:noreply,
     push_event(socket, "download", %{
       filename: "#{socket.assigns.job.book.slug}.json",
       content: socket.assigns.preview_json
     })}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PdfPipelineWeb.Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">Export: {@job.metadata[:slug]}</h1>
            <p class="text-base-content/60">
              Preview, validate, and export to data-library format.
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/review/#{@job.id}/edit"} class="btn btn-ghost">
              Back to Editor
            </.link>
          </div>
        </div>

        <%!-- Stats & Validation --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="card bg-base-200">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Book Stats</h3>
              <div class="grid grid-cols-2 gap-2 text-sm">
                <div>Chapters:</div><div class="font-mono">{Book.chapter_count(@job.book)}</div>
                <div>Paragraphs:</div><div class="font-mono">{@stats.total}</div>
                <div>Confidence:</div><div class="font-mono">{@stats.percentage_clear}%</div>
                <div>Ambiguous:</div><div class="font-mono">{@stats.ambiguous}</div>
                <div>File size:</div><div class="font-mono">{Float.round(byte_size(@preview_json) / 1024, 1)} KB</div>
              </div>
            </div>
          </div>

          <div class="card bg-base-200">
            <div class="card-body p-4">
              <h3 class="card-title text-sm">Validation</h3>
              <%= case @validation do %>
                <% {:ok, _} -> %>
                  <div class="flex items-center gap-2 text-success">
                    <span class="badge badge-success badge-sm">VALID</span>
                    Schema validation passed
                  </div>
                <% {:error, errors} -> %>
                  <div class="space-y-1">
                    <span class="badge badge-error badge-sm">INVALID</span>
                    <%= for error <- errors do %>
                      <p class="text-error text-sm">{error}</p>
                    <% end %>
                  </div>
              <% end %>

              <div class="card-actions justify-end mt-4">
                <button phx-click="download" class="btn btn-ghost btn-sm">
                  Download JSON
                </button>
                <button
                  phx-click="export"
                  class="btn btn-primary btn-sm"
                  disabled={match?({:error, _}, @validation)}
                >
                  <%= if @exported do %>
                    Re-export to data-library
                  <% else %>
                    Export to data-library
                  <% end %>
                </button>
              </div>

              <%= if @exported do %>
                <div class="mt-2 text-sm text-success">
                  Exported to: <code class="text-xs">{@export_path}</code>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- JSON Preview --%>
        <div class="card bg-base-200">
          <div class="card-body p-4">
            <h3 class="card-title text-sm">JSON Preview</h3>
            <div class="bg-base-100 rounded-lg p-4 max-h-[600px] overflow-auto">
              <pre class="text-xs font-mono whitespace-pre">{@preview_json}</pre>
            </div>
          </div>
        </div>
      </div>
    </PdfPipelineWeb.Layouts.app>
    """
  end
end
