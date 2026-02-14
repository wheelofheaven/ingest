defmodule Mix.Tasks.Curator.Export do
  @moduledoc """
  Exports a processed book to data-library format (Stage 4).

  Reads from `_work/{slug}/` and writes to the data-library directory.

  ## Usage

      mix curator.export --slug my-book
      mix curator.export --slug my-book --output ../data-library

  ## Options

  - `--slug` — Book slug (required)
  - `--output` — Output directory (default: configured DATA_LIBRARY_PATH)
  """

  use Mix.Task

  @shortdoc "Export processed book to data-library JSON format"

  @switches [
    slug: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} = OptionParser.parse(args, strict: @switches)

    slug = opts[:slug] || Mix.raise("--slug is required")

    Mix.Task.run("app.start")

    unless Curator.Stages.Normalize.done?(slug) do
      Mix.raise("No normalized output found for '#{slug}'. Run `mix curator.normalize` first.")
    end

    export_opts =
      case opts[:output] do
        nil -> []
        dir -> [output_dir: dir]
      end

    translated? = Curator.Stages.Translate.done?(slug)

    Mix.shell().info("Exporting to data-library...")
    Mix.shell().info("  Slug: #{slug}")
    Mix.shell().info("  Translated: #{translated?}")
    if opts[:output], do: Mix.shell().info("  Output: #{opts[:output]}")
    Mix.shell().info("")

    case Curator.Stages.Export.run(slug, export_opts) do
      {:ok, path} ->
        Mix.shell().info("Export complete!")
        Mix.shell().info("  Output: #{path}")

      {:error, reason} ->
        Mix.raise("Export failed: #{inspect(reason)}")
    end
  end
end
