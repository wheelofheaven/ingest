defmodule PdfPipelineWeb.DashboardLive do
  use PdfPipelineWeb, :live_view

  alias PdfPipeline.Store.Job
  alias PdfPipeline.Pipeline
  alias PdfPipeline.Stages

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PdfPipeline.PubSub, "jobs")
    end

    jobs = Job.list()

    {:ok,
     socket
     |> assign(:jobs, jobs)
     |> assign(:work_status, %{})
     |> assign(:form, to_form(%{
       "slug" => "",
       "code" => "",
       "lang" => "fr",
       "title" => "",
       "rules" => "default",
       "year" => ""
     }))
     |> allow_upload(:pdf, accept: ~w(.pdf), max_entries: 1, max_file_size: 50_000_000)}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["pdf"]} = _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  @impl true
  def handle_event("start_pipeline", params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :pdf, fn %{path: path}, _entry ->
        dest = Path.join(System.tmp_dir!(), "pdf_pipeline_#{System.unique_integer([:positive])}.pdf")
        File.cp!(path, dest)
        {:ok, dest}
      end)

    case uploaded_files do
      [pdf_path] ->
        metadata = %{
          slug: params["slug"],
          code: String.upcase(params["code"]),
          primary_lang: params["lang"],
          title: params["title"],
          publication_year: parse_year(params["year"])
        }

        opts = [rules: params["rules"] || "default"]

        Task.start(fn ->
          Pipeline.run(pdf_path, metadata, opts)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Pipeline started! Processing...")
         |> assign(:jobs, Job.list())}

      _ ->
        {:noreply, put_flash(socket, :error, "Please upload a PDF file")}
    end
  end

  def handle_event("check_status", %{"slug" => slug}, socket) do
    status = Pipeline.status(slug)
    work_status = Map.put(socket.assigns.work_status, slug, status)
    {:noreply, assign(socket, :work_status, work_status)}
  end

  def handle_event("run_stage", %{"stage" => stage, "slug" => slug} = params, socket) do
    Task.start(fn ->
      case stage do
        "ocr" ->
          pdf_path = params["pdf_path"]
          if pdf_path, do: Stages.OCR.run(pdf_path, slug)

        "normalize" ->
          metadata = %{
            slug: slug,
            code: params["code"] || "",
            primary_lang: params["lang"] || "fr"
          }
          Stages.Normalize.run(slug, metadata, rules: params["rules"] || "default")

        "translate" ->
          Stages.Translate.run(slug)

        "export" ->
          Stages.Export.run(slug)
      end
    end)

    {:noreply, put_flash(socket, :info, "Stage '#{stage}' started for #{slug}")}
  end

  @impl true
  def handle_info({:job_updated, _job}, socket) do
    {:noreply, assign(socket, :jobs, Job.list())}
  end

  defp parse_year(""), do: nil
  defp parse_year(nil), do: nil

  defp parse_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp status_badge(status) do
    case status do
      :pending -> "badge-ghost"
      :ocr -> "badge-info"
      :parsing -> "badge-info"
      :refining -> "badge-warning"
      :translating -> "badge-warning"
      :exporting -> "badge-warning"
      :complete -> "badge-success"
      :error -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp stage_icon(true), do: "text-success"
  defp stage_icon(false), do: "text-base-content/30"

  @impl true
  def render(assigns) do
    ~H"""
    <PdfPipelineWeb.Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-bold">PDF Pipeline Dashboard</h1>
          <p class="text-base-content/60 mt-1">
            Ingest PDFs into the data-library structured JSON format.
          </p>
          <p class="text-sm text-base-content/40 mt-1">
            Stages: OCR → Normalize → Translate → Export (each independently runnable via CLI)
          </p>
        </div>

        <%!-- New Job Form --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">New Ingestion Job</h2>

            <.form for={@form} phx-change="validate" phx-submit="start_pipeline" class="space-y-4">
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">PDF File</span></label>
                  <.live_file_input upload={@uploads.pdf} class="file-input file-input-bordered w-full" />
                  <%= for entry <- @uploads.pdf.entries do %>
                    <div class="text-sm mt-1 text-base-content/60">
                      {entry.client_name} ({Float.round(entry.client_size / 1_000_000, 1)} MB)
                      <progress class="progress progress-primary w-full" value={entry.progress} max="100" />
                    </div>
                  <% end %>
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Book Slug</span></label>
                  <input
                    type="text"
                    name="slug"
                    value={@form.params["slug"]}
                    placeholder="the-book-which-tells-the-truth"
                    class="input input-bordered w-full"
                    required
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Book Code</span></label>
                  <input
                    type="text"
                    name="code"
                    value={@form.params["code"]}
                    placeholder="TBWTT"
                    class="input input-bordered w-full"
                    required
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Primary Language</span></label>
                  <select name="lang" class="select select-bordered w-full">
                    <option value="fr" selected={@form.params["lang"] == "fr"}>French (fr)</option>
                    <option value="en" selected={@form.params["lang"] == "en"}>English (en)</option>
                    <option value="de" selected={@form.params["lang"] == "de"}>German (de)</option>
                    <option value="es" selected={@form.params["lang"] == "es"}>Spanish (es)</option>
                    <option value="ja" selected={@form.params["lang"] == "ja"}>Japanese (ja)</option>
                    <option value="zh" selected={@form.params["lang"] == "zh"}>Chinese (zh)</option>
                    <option value="ru" selected={@form.params["lang"] == "ru"}>Russian (ru)</option>
                    <option value="he" selected={@form.params["lang"] == "he"}>Hebrew (he)</option>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Book Title</span></label>
                  <input
                    type="text"
                    name="title"
                    value={@form.params["title"]}
                    placeholder="Le Livre Qui Dit la Vérité"
                    class="input input-bordered w-full"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Publication Year</span></label>
                  <input
                    type="text"
                    name="year"
                    value={@form.params["year"]}
                    placeholder="1973"
                    class="input input-bordered w-full"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Rule Profile</span></label>
                  <select name="rules" class="select select-bordered w-full">
                    <option value="default" selected={@form.params["rules"] == "default"}>Default</option>
                    <option value="raelian" selected={@form.params["rules"] == "raelian"}>Raëlian</option>
                  </select>
                </div>
              </div>

              <div class="card-actions justify-end">
                <button type="submit" class="btn btn-primary">
                  Start Pipeline
                </button>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Jobs List --%>
        <div>
          <h2 class="text-xl font-semibold mb-4">Jobs</h2>

          <%= if @jobs == [] do %>
            <div class="text-center py-12 text-base-content/40">
              <p>No jobs yet. Upload a PDF to get started.</p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-zebra w-full">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>PDF</th>
                    <th>Slug</th>
                    <th>Status</th>
                    <th>Started</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for job <- @jobs do %>
                    <tr>
                      <td class="font-mono text-sm">{String.slice(job.id, 0, 8)}</td>
                      <td>{Path.basename(job.pdf_path)}</td>
                      <td>{job.metadata[:slug]}</td>
                      <td>
                        <span class={"badge #{status_badge(job.status)}"}>
                          {job.status}
                        </span>
                      </td>
                      <td class="text-sm">{Calendar.strftime(job.started_at, "%H:%M:%S")}</td>
                      <td>
                        <%= if job.status == :complete do %>
                          <.link navigate={~p"/review/#{job.id}"} class="btn btn-sm btn-ghost">
                            Review
                          </.link>
                          <.link navigate={~p"/review/#{job.id}/export"} class="btn btn-sm btn-primary">
                            Export
                          </.link>
                        <% end %>
                        <%= if job.status in [:ocr, :parsing, :refining, :translating, :exporting] do %>
                          <span class="loading loading-spinner loading-sm"></span>
                        <% end %>
                        <%= if job.status == :error do %>
                          <span class="text-error text-sm">{List.first(job.errors)}</span>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>

        <%!-- Work Directory Status --%>
        <%= if @work_status != %{} do %>
          <div>
            <h2 class="text-xl font-semibold mb-4">Work Directory Status</h2>
            <%= for {slug, status} <- @work_status do %>
              <div class="card bg-base-200 shadow-sm mb-4">
                <div class="card-body">
                  <h3 class="card-title font-mono">{slug}</h3>
                  <div class="flex gap-4">
                    <span class={stage_icon(status.ocr)}>OCR</span>
                    <span>→</span>
                    <span class={stage_icon(status.normalize)}>Normalize</span>
                    <span>→</span>
                    <span class={stage_icon(status.translate)}>Translate</span>
                  </div>
                  <%= if status.artifacts != [] do %>
                    <div class="text-sm text-base-content/60 mt-2">
                      Artifacts: {Enum.join(status.artifacts, ", ")}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </PdfPipelineWeb.Layouts.app>
    """
  end
end
