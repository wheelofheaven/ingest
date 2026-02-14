defmodule CuratorWeb.DashboardLive do
  use CuratorWeb, :live_view

  alias Curator.Store.Job
  alias Curator.Pipeline
  alias Curator.Stages
  alias Curator.Sources
  alias Curator.Ecosystem

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Curator.PubSub, "jobs")
    end

    jobs = Job.list()
    sources = Sources.list_sources()
    source_dir = Sources.source_dir()
    work_slugs = scan_work_dirs()

    library_catalog = Ecosystem.library_catalog()
    content_stats = Ecosystem.content_stats()
    images_stats = Ecosystem.images_stats()

    {:ok,
     socket
     |> assign(:jobs, jobs)
     |> assign(:sources, sources)
     |> assign(:source_dir, source_dir)
     |> assign(:selected_source, nil)
     |> assign(:selected_book, nil)
     |> assign(:work_slugs, work_slugs)
     |> assign(:library_catalog, library_catalog)
     |> assign(:content_stats, content_stats)
     |> assign(:images_stats, images_stats)
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
            dest = Path.join(System.tmp_dir!(), "curator_#{System.unique_integer([:positive])}.pdf")
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
    {:noreply,
     socket
     |> assign(:jobs, Job.list())
     |> assign(:work_slugs, scan_work_dirs())}
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

  defp stage_badge(true), do: "badge-success"
  defp stage_badge(false), do: "badge-ghost"

  defp display_name(name) when is_binary(name), do: name
  defp display_name(name) when is_map(name), do: name["en"] || name |> Map.values() |> List.first() || ""
  defp display_name(_), do: ""

  defp book_status_badge("complete"), do: "badge-success"
  defp book_status_badge("draft"), do: "badge-warning"
  defp book_status_badge("planned"), do: "badge-ghost"
  defp book_status_badge(_), do: "badge-ghost"

  defp translation_coverage(lang_counts, base_counts) do
    total_base = Enum.reduce(base_counts, 0, fn {_k, v}, acc -> acc + v end)
    total_lang = Enum.reduce(lang_counts, 0, fn {_k, v}, acc -> acc + v end)

    if total_base > 0 do
      round(total_lang / total_base * 100)
    else
      0
    end
  end

  defp coverage_text_class(pct) when pct >= 80, do: "text-success"
  defp coverage_text_class(pct) when pct >= 40, do: "text-warning"
  defp coverage_text_class(_pct), do: "text-error"

  defp scan_work_dirs do
    Stages.WorkDir.list_slugs()
    |> Enum.map(fn slug ->
      status = Pipeline.status(slug)
      %{slug: slug, status: status}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <CuratorWeb.Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-bold">Curator Dashboard</h1>
          <p class="text-base-content/60 mt-1">
            Curate source documents into the data-library structured JSON format.
          </p>
          <p class="text-sm text-base-content/40 mt-1">
            Stages: OCR → Normalize → Translate → Export (each independently runnable via CLI)
          </p>
        </div>

        <%!-- Ecosystem Overview --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Ecosystem Overview</h2>
            <p class="text-sm text-base-content/60 mb-3">
              Live data from sibling repositories: data-library, data-content, data-images.
            </p>

            <%!-- Stats Row --%>
            <div class="stats stats-vertical md:stats-horizontal shadow w-full">
              <div class="stat">
                <div class="stat-title">Library Books</div>
                <div class="stat-value text-lg">{@library_catalog.book_count}</div>
                <div class="stat-desc">
                  {@library_catalog.tradition_count} traditions, {@library_catalog.collection_count} collections
                </div>
              </div>
              <div class="stat">
                <div class="stat-title">Content Files</div>
                <div class="stat-value text-lg">{@content_stats.total_files}</div>
                <div class="stat-desc">
                  across {@content_stats.sections |> Map.keys() |> length()} sections
                </div>
              </div>
              <div class="stat">
                <div class="stat-title">Raw Images</div>
                <div class="stat-value text-lg">{@images_stats.raw_count}</div>
                <div class="stat-desc">{@images_stats.processed_count} processed outputs</div>
              </div>
              <div class="stat">
                <div class="stat-title">Manifest Entries</div>
                <div class="stat-value text-lg">{@images_stats.manifest_entries}</div>
                <div class="stat-desc">
                  {@images_stats.categories |> Map.keys() |> length()} categories
                </div>
              </div>
            </div>

            <%!-- Data Library Catalog --%>
            <div class="collapse collapse-arrow bg-base-100 mt-4">
              <input type="checkbox" checked />
              <div class="collapse-title font-medium">
                Data Library Catalog
                <span class="badge badge-sm ml-2">{@library_catalog.book_count} books</span>
              </div>
              <div class="collapse-content">
                <%= if @library_catalog.ok do %>
                  <%= for tradition <- @library_catalog.traditions do %>
                    <div class="mb-4">
                      <h4 class="font-semibold text-sm mb-2">
                        <span class="badge badge-outline badge-sm mr-1">{tradition["code"]}</span>
                        {display_name(tradition["name"])}
                      </h4>
                      <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                        <%= for book <- Enum.filter(@library_catalog.books, & &1["tradition"] == tradition["slug"]) do %>
                          <div class="card card-compact bg-base-200">
                            <div class="card-body p-3">
                              <div class="flex items-start justify-between gap-2">
                                <div class="min-w-0">
                                  <p class="font-medium text-sm truncate">{book["slug"]}</p>
                                  <p class="text-xs text-base-content/50">
                                    {book["code"]} · {book["publicationYear"]}
                                  </p>
                                </div>
                                <span class={"badge badge-xs #{book_status_badge(book["status"])}"}>
                                  {book["status"]}
                                </span>
                              </div>
                              <div class="flex gap-1 flex-wrap mt-1">
                                <span class="text-xs text-base-content/50">
                                  {book["chapters"] || 0} ch · {book["paragraphs"] || 0} para
                                </span>
                              </div>
                              <div class="flex gap-1 flex-wrap mt-1">
                                <%= for lang <- (book["availableLangs"] || []) do %>
                                  <%= if lang in (book["completeLangs"] || []) do %>
                                    <span class="badge badge-xs badge-success">{lang}</span>
                                  <% else %>
                                    <span class="badge badge-xs badge-ghost">{lang}</span>
                                  <% end %>
                                <% end %>
                              </div>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% else %>
                  <p class="text-sm text-base-content/40">catalog.json not found in data-library.</p>
                <% end %>
              </div>
            </div>

            <%!-- Content Stats --%>
            <div class="collapse collapse-arrow bg-base-100 mt-2">
              <input type="checkbox" />
              <div class="collapse-title font-medium">
                Content Stats
                <span class="badge badge-sm ml-2">{@content_stats.total_files} files</span>
              </div>
              <div class="collapse-content">
                <%= if @content_stats.ok do %>
                  <div class="mb-4">
                    <h4 class="font-semibold text-sm mb-2">Base Sections (English)</h4>
                    <div class="flex gap-4 flex-wrap">
                      <%= for {section, count} <- @content_stats.sections do %>
                        <div class="text-center">
                          <div class="text-lg font-bold">{count}</div>
                          <div class="text-xs text-base-content/60">{section}</div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <h4 class="font-semibold text-sm mb-2">Translation Coverage</h4>
                  <div class="overflow-x-auto">
                    <table class="table table-xs w-full">
                      <thead>
                        <tr>
                          <th>Lang</th>
                          <%= for section <- ~w(wiki timeline essentials resources) do %>
                            <th class="text-center">{section}</th>
                          <% end %>
                          <th class="text-center">Coverage</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for lang <- @content_stats.available_languages do %>
                          <% lang_counts = @content_stats.languages[lang] || %{} %>
                          <% pct = translation_coverage(lang_counts, @content_stats.sections) %>
                          <tr>
                            <td class="font-mono font-semibold">{lang}</td>
                            <%= for section <- ~w(wiki timeline essentials resources) do %>
                              <td class="text-center">{lang_counts[section] || 0}</td>
                            <% end %>
                            <td class="text-center">
                              <div class="flex items-center gap-2">
                                <progress
                                  class="progress progress-primary w-16"
                                  value={pct}
                                  max="100"
                                />
                                <span class={"text-xs font-semibold #{coverage_text_class(pct)}"}>{pct}%</span>
                              </div>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% else %>
                  <p class="text-sm text-base-content/40">data-content directory not found.</p>
                <% end %>
              </div>
            </div>

            <%!-- Image Inventory --%>
            <div class="collapse collapse-arrow bg-base-100 mt-2">
              <input type="checkbox" />
              <div class="collapse-title font-medium">
                Image Inventory
                <span class="badge badge-sm ml-2">{@images_stats.raw_count} raw</span>
              </div>
              <div class="collapse-content">
                <%= if @images_stats.ok do %>
                  <h4 class="font-semibold text-sm mb-2">Categories from Manifest</h4>
                  <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
                    <%= for {category, count} <- Enum.sort_by(@images_stats.categories, fn {_k, v} -> -v end) do %>
                      <div class="card card-compact bg-base-200">
                        <div class="card-body p-3 text-center">
                          <div class="text-lg font-bold">{count}</div>
                          <div class="text-xs text-base-content/60">{category}</div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <p class="text-sm text-base-content/40">manifest.yaml not found in data-images.</p>
                <% end %>
              </div>
            </div>
          </div>
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
                  New Curation Job
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

        <%!-- Work Directories --%>
        <%= if @work_slugs != [] do %>
          <div>
            <h2 class="text-xl font-semibold mb-4">Work Directories</h2>
            <p class="text-sm text-base-content/50 mb-3">
              Intermediate artifacts in <code class="text-xs">_work/</code> — OCR results are cached and won't be re-fetched.
            </p>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <%= for ws <- @work_slugs do %>
                <div class="card bg-base-200 shadow-sm">
                  <div class="card-body p-4">
                    <h3 class="font-mono text-sm font-semibold">{ws.slug}</h3>
                    <div class="flex gap-2 my-1">
                      <span class={"badge badge-xs #{stage_badge(ws.status.ocr)}"}>OCR</span>
                      <span class="text-base-content/30">-></span>
                      <span class={"badge badge-xs #{stage_badge(ws.status.normalize)}"}>Normalize</span>
                      <span class="text-base-content/30">-></span>
                      <span class={"badge badge-xs #{stage_badge(ws.status.translate)}"}>Translate</span>
                    </div>
                    <div class="text-xs text-base-content/40">
                      {Enum.join(ws.status.artifacts, ", ")}
                    </div>
                    <div class="card-actions justify-end mt-2">
                      <%= if ws.status.normalize do %>
                        <.link navigate={~p"/edit/#{ws.slug}"} class="btn btn-primary btn-xs">
                          Edit
                        </.link>
                      <% end %>
                      <%= if ws.status.ocr && !ws.status.normalize do %>
                        <button
                          phx-click="run_stage"
                          phx-value-stage="normalize"
                          phx-value-slug={ws.slug}
                          class="btn btn-sm btn-ghost"
                        >
                          Normalize
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </CuratorWeb.Layouts.app>
    """
  end
end
