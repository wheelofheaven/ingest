defmodule PdfPipelineWeb.DashboardLive do
  use PdfPipelineWeb, :live_view

  alias PdfPipeline.Store.Job
  alias PdfPipeline.Pipeline
  alias PdfPipeline.Stages
  alias PdfPipeline.Sources

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PdfPipeline.PubSub, "jobs")
    end

    jobs = Job.list()
    sources = Sources.list_sources()
    source_dir = Sources.source_dir()

    {:ok,
     socket
     |> assign(:jobs, jobs)
     |> assign(:sources, sources)
     |> assign(:source_dir, source_dir)
     |> assign(:selected_source, nil)
     |> assign(:selected_book, nil)
     |> assign(:work_status, %{})
     |> assign(:form, to_form(empty_form()))
     |> allow_upload(:pdf, accept: ~w(.pdf), max_entries: 1, max_file_size: 50_000_000)}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["pdf"]} = _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  def handle_event("select_source", %{"path" => path}, socket) do
    source = Enum.find(socket.assigns.sources, &(&1.path == path))

    case source do
      nil ->
        {:noreply, socket}

      %{books: [single_book]} ->
        # Single book — fill form immediately
        {:noreply,
         socket
         |> assign(:selected_source, source)
         |> assign(:selected_book, single_book)
         |> assign(:form, to_form(form_from_sidecar(single_book)))}

      %{books: [_ | _]} ->
        # Anthology — show book picker, prefill shared fields
        {:noreply,
         socket
         |> assign(:selected_source, source)
         |> assign(:selected_book, nil)
         |> assign(:form, to_form(form_from_sidecar(source.sidecar)))}

      %{books: []} ->
        # No sidecar metadata
        {:noreply,
         socket
         |> assign(:selected_source, source)
         |> assign(:selected_book, nil)}
    end
  end

  def handle_event("select_book", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    source = socket.assigns.selected_source

    case Enum.at(source.books, index) do
      nil ->
        {:noreply, socket}

      book ->
        {:noreply,
         socket
         |> assign(:selected_book, book)
         |> assign(:form, to_form(form_from_sidecar(book)))}
    end
  end

  def handle_event("clear_source", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_source, nil)
     |> assign(:selected_book, nil)
     |> assign(:form, to_form(empty_form()))}
  end

  @impl true
  def handle_event("start_pipeline", params, socket) do
    source = socket.assigns.selected_source

    # Determine the PDF path: from selected source or from upload
    {pdf_path, socket} =
      if source do
        {source.path, socket}
      else
        uploaded_files =
          consume_uploaded_entries(socket, :pdf, fn %{path: path}, _entry ->
            dest = Path.join(System.tmp_dir!(), "pdf_pipeline_#{System.unique_integer([:positive])}.pdf")
            File.cp!(path, dest)
            {:ok, dest}
          end)

        case uploaded_files do
          [path] -> {path, socket}
          _ -> {nil, socket}
        end
      end

    if pdf_path do
      metadata = %{
        slug: params["slug"],
        code: String.upcase(params["code"] || ""),
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
       |> assign(:jobs, Job.list())
       |> assign(:selected_source, nil)
       |> assign(:selected_book, nil)
       |> assign(:form, to_form(empty_form()))}
    else
      {:noreply, put_flash(socket, :error, "Please select a source PDF or upload a file")}
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

  # Helpers

  defp empty_form do
    %{
      "slug" => "",
      "code" => "",
      "lang" => "fr",
      "title" => "",
      "rules" => "default",
      "year" => ""
    }
  end

  defp form_from_sidecar(nil), do: empty_form()

  defp form_from_sidecar(meta) do
    %{
      "slug" => meta["slug"] || "",
      "code" => meta["code"] || "",
      "lang" => meta["language"] || "fr",
      "title" => meta["title"] || "",
      "rules" => meta["rules"] || "default",
      "year" => to_string(meta["year"] || "")
    }
  end

  defp parse_year(""), do: nil
  defp parse_year(nil), do: nil

  defp parse_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp format_size(bytes) when bytes < 1_000_000 do
    "#{Float.round(bytes / 1_000, 0)} KB"
  end

  defp format_size(bytes) do
    "#{Float.round(bytes / 1_000_000, 1)} MB"
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

        <%!-- Source Library --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Source Library</h2>
            <p class="text-sm text-base-content/60 mb-3">
              <span class="font-mono text-xs">{@source_dir}</span>
            </p>

            <%= if @sources == [] do %>
              <div class="text-center py-6 text-base-content/40">
                <p>No PDFs found in source directory.</p>
                <p class="text-xs mt-1">
                  Set <code>DATA_SOURCES_PATH</code> in your <code>.env</code> file.
                </p>
              </div>
            <% else %>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <%= for source <- @sources do %>
                  <button
                    type="button"
                    phx-click="select_source"
                    phx-value-path={source.path}
                    class={"card card-compact bg-base-100 cursor-pointer hover:shadow-md transition-shadow border-2 #{if @selected_source && @selected_source.path == source.path, do: "border-primary", else: "border-transparent"}"}
                  >
                    <div class="card-body">
                      <div class="flex items-start gap-2">
                        <span class="text-xl">
                          <%= if source.sidecar, do: "📖", else: "📄" %>
                        </span>
                        <div class="min-w-0 text-left">
                          <p class="font-medium text-sm truncate">
                            <%= if source.sidecar do %>
                              {source.sidecar["title"]}
                            <% else %>
                              {source.filename}
                            <% end %>
                          </p>
                          <p class="text-xs text-base-content/50">
                            {source.relative} · {format_size(source.size)}
                          </p>
                          <%= if source.sidecar do %>
                            <div class="flex gap-1 mt-1 flex-wrap">
                              <span class="badge badge-xs">{source.sidecar["language"]}</span>
                              <%= if source.sidecar["type"] == "anthology" do %>
                                <span class="badge badge-xs badge-outline">
                                  {length(source.books)} books
                                </span>
                              <% end %>
                              <%= if source.sidecar["tradition"] do %>
                                <span class="badge badge-xs badge-ghost">
                                  {source.sidecar["tradition"]}
                                </span>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Book Picker (for anthologies) --%>
        <%= if @selected_source && length(@selected_source.books) > 1 do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title">
                  Select Book from "{@selected_source.sidecar["title"]}"
                </h2>
                <button type="button" phx-click="clear_source" class="btn btn-ghost btn-sm">
                  Clear
                </button>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mt-2">
                <%= for {book, idx} <- Enum.with_index(@selected_source.books) do %>
                  <button
                    type="button"
                    phx-click="select_book"
                    phx-value-index={idx}
                    class={"card card-compact bg-base-100 cursor-pointer hover:shadow-md transition-shadow border-2 #{if @selected_book && @selected_book["slug"] == book["slug"], do: "border-primary", else: "border-transparent"}"}
                  >
                    <div class="card-body">
                      <p class="font-medium text-sm">{book["title"]}</p>
                      <p class="text-xs text-base-content/50">
                        {book["code"]} · {book["year"]}
                      </p>
                    </div>
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- New Job Form --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">
                <%= if @selected_source do %>
                  Pipeline Configuration
                <% else %>
                  New Ingestion Job
                <% end %>
              </h2>
              <%= if @selected_source do %>
                <button type="button" phx-click="clear_source" class="btn btn-ghost btn-sm">
                  Clear
                </button>
              <% end %>
            </div>

            <%= if @selected_source do %>
              <div class="flex items-center gap-2 text-sm text-base-content/60 mb-2">
                <span>📄</span>
                <span class="font-mono text-xs">{@selected_source.relative}</span>
              </div>
            <% end %>

            <.form for={@form} phx-change="validate" phx-submit="start_pipeline" class="space-y-4">
              <%= if !@selected_source do %>
                <div class="form-control">
                  <label class="label"><span class="label-text">Upload PDF (or select from source library above)</span></label>
                  <.live_file_input upload={@uploads.pdf} class="file-input file-input-bordered w-full" />
                  <%= for entry <- @uploads.pdf.entries do %>
                    <div class="text-sm mt-1 text-base-content/60">
                      {entry.client_name} ({Float.round(entry.client_size / 1_000_000, 1)} MB)
                      <progress class="progress progress-primary w-full" value={entry.progress} max="100" />
                    </div>
                  <% end %>
                </div>
              <% end %>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
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
              <p>No jobs yet. Select a source PDF or upload one to get started.</p>
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
