defmodule Mix.Tasks.Pdf.Translate do
  @moduledoc """
  Translates a normalized book into target languages (Stage 3).

  Reads from `_work/{slug}/book.json` and writes `_work/{slug}/book_translated.json`.

  ## Usage

      mix pdf.translate --slug my-book
      mix pdf.translate --slug my-book --langs en,de,es

  ## Options

  - `--slug` — Book slug (required)
  - `--langs` — Comma-separated target languages (default: all configured)
  - `--force` — Re-run even if output exists
  - `--preserve` — Comma-separated additional terms to keep untranslated
  """

  use Mix.Task

  @shortdoc "Translate normalized book into target languages"

  @switches [
    slug: :string,
    langs: :string,
    force: :boolean,
    preserve: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} = OptionParser.parse(args, strict: @switches)

    slug = opts[:slug] || Mix.raise("--slug is required")

    Mix.Task.run("app.start")

    unless PdfPipeline.Stages.Normalize.done?(slug) do
      Mix.raise("No normalized output found for '#{slug}'. Run `mix pdf.normalize` first.")
    end

    if PdfPipeline.Stages.Translate.done?(slug) && !opts[:force] do
      Mix.shell().info("Translated output already exists for '#{slug}'. Use --force to re-run.")
      Mix.shell().info("  Path: #{PdfPipeline.Stages.WorkDir.artifact(slug, "book_translated.json")}")
    else
      langs =
        case opts[:langs] do
          nil -> Application.get_env(:pdf_pipeline, :default_languages, ~w(en fr de es ru ja zh))
          str -> String.split(str, ",", trim: true)
        end

      preserve =
        case opts[:preserve] do
          nil -> []
          str -> String.split(str, ",", trim: true)
        end

      translate_opts = [
        langs: langs,
        preserve_terms: preserve
      ]

      Mix.shell().info("Starting translation...")
      Mix.shell().info("  Slug: #{slug}")
      Mix.shell().info("  Target languages: #{Enum.join(langs, ", ")}")
      if preserve != [], do: Mix.shell().info("  Preserve terms: #{Enum.join(preserve, ", ")}")
      Mix.shell().info("")

      case PdfPipeline.Stages.Translate.run(slug, translate_opts) do
        {:ok, result} ->
          Mix.shell().info("Translation complete!")
          Mix.shell().info("  Output: #{result.path}")
          Mix.shell().info("")
          Mix.shell().info("Next step: mix pdf.export --slug #{slug}")

        {:error, reason} ->
          Mix.raise("Translation failed: #{inspect(reason)}")
      end
    end
  end
end
