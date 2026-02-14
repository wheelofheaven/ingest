# Get Started

## Prerequisites

- [mise](https://mise.jdx.dev/) for tool version management and task running
- A [z.ai](https://open.bigmodel.cn/) API key (used for OCR and LLM features)

mise will install the correct versions of Erlang and Elixir automatically.

## Setup

Clone the repo and install dependencies:

```sh
git clone git@github.com:wheelofheaven/curator.git
cd curator
mise install        # Installs Erlang 28 + Elixir 1.19
mise run setup      # mix deps.get && mix compile
```

## API Key

Create a `.env` file from the example and add your z.ai API key:

```sh
cp .env.example .env
```

Edit `.env`:

```
ZAI_API_KEY=your_key_here
ANTHROPIC_API_KEY=            # Optional, for Anthropic fallback
```

mise loads `.env` automatically on every command.

## Directory Layout

The pipeline expects sibling directories for data:

```
wheelofheaven/
  curator/               # This repo
  data-library/               # Output: structured JSON books
  data-sources/               # Input: source PDFs with sidecar metadata
    pdf/
      _combined/
        book.pdf
        book.json             # Sidecar metadata
```

The paths are configured in `mise.toml` and can be overridden:

```
DATA_LIBRARY_PATH=../data-library
DATA_SOURCES_PATH=../data-sources
```

## Your First Curation

### Option A: Step-by-Step (Recommended)

Run each stage individually so you can inspect and correct intermediate results.

**1. OCR &mdash; Extract text from PDF**

```sh
mise run ocr -- ../data-sources/pdf/_combined/book.pdf --slug my-book
```

This creates `_work/my-book/ocr.md`. Open it to verify the OCR quality.

**2. Normalize &mdash; Parse into structured JSON**

```sh
mise run normalize -- --slug my-book --code MB --lang fr --rules raelian
```

This reads `_work/my-book/ocr.md` and creates `_work/my-book/book.json`.
Open it to review chapters, paragraphs, and speaker attributions.

**3. Translate &mdash; Fill i18n slots (optional)**

```sh
mise run translate -- --slug my-book --langs en,de
```

Translates into English and German, saving to
`_work/my-book/book_translated.json`.

**4. Export &mdash; Write to data-library**

```sh
mise run export -- --slug my-book
```

Writes the final JSON to `../data-library/my-book/`.

### Option B: Full Pipeline

Run everything in one command:

```sh
mise run curator -- ../data-sources/pdf/_combined/book.pdf \
  --slug my-book \
  --code MB \
  --lang fr \
  --rules raelian
```

Add `--translate --langs en,de` to include translation.

## Sidecar Metadata

If a `.json` file sits alongside the PDF with the same name, metadata is
loaded automatically:

```
data-sources/pdf/_combined/
  le-message-donne-par-les-extra-terrestres.pdf
  le-message-donne-par-les-extra-terrestres.json   <-- sidecar
```

Example sidecar JSON:

```json
{
  "title": "Le Message Donne par les Extra-Terrestres",
  "slug": "the-book-which-tells-the-truth",
  "code": "TBWTT",
  "language": "fr",
  "author": "Rael",
  "year": 1974,
  "tradition": "raelian",
  "collection": "raelian-messages",
  "rules": "raelian"
}
```

With a sidecar, you can skip all CLI flags:

```sh
mise run ocr -- ../data-sources/pdf/_combined/le-message-donne-par-les-extra-terrestres.pdf
```

CLI flags always override sidecar values when both are present.

## Web Interface

Start the Phoenix dev server:

```sh
mise run serve
```

Open [http://localhost:4000](http://localhost:4000) to use the web dashboard
for uploading PDFs, reviewing results, editing paragraphs, and exporting.

## Interactive Shell

For exploration and debugging:

```sh
mise run iex
```

Then in IEx:

```elixir
# Check stage status
Curator.Pipeline.status("my-book")

# Load and inspect a normalized book
{:ok, json} = Curator.Stages.Normalize.load("my-book")
length(json["chapters"])

# Run OCR programmatically
{:ok, result} = Curator.Stages.OCR.run("path/to/book.pdf", "my-book")
```

## Rule Profiles

Rule profiles control how the parser splits text into chapters and paragraphs.
They live in `priv/rules/`:

| Profile    | File                     | Description                           |
|------------|--------------------------|---------------------------------------|
| `default`  | `priv/rules/default.json`  | Generic chapter/paragraph patterns    |
| `raelian`  | `priv/rules/raelian.json`  | CHAPITRE headings, known speakers     |

Pass the profile name with `--rules`:

```sh
mise run normalize -- --slug my-book --code MB --lang fr --rules raelian
```

## Common Tasks

| Task               | Command                                          |
|--------------------|--------------------------------------------------|
| Install deps       | `mise run setup`                                 |
| Run tests          | `mise run test`                                  |
| Format code        | `mise run format`                                |
| Lint               | `mise run lint`                                  |
| Start dev server   | `mise run serve`                                 |
| Interactive shell  | `mise run iex`                                   |
| Clean build        | `mise run clean`                                 |
| Full reset         | `mise run reset`                                 |

## Troubleshooting

**"ZAI_API_KEY not configured"**
Make sure your `.env` file exists and contains a valid key. Run `mise env` to
verify it's being loaded.

**"No OCR output found for 'my-book'"**
You need to run `mise run ocr` before `mise run normalize`. Stages depend on
each other's artifacts.

**OCR output looks wrong**
The GLM-OCR model works best with clean, high-resolution PDFs. Scanned
documents with poor quality may need manual cleanup of `_work/{slug}/ocr.md`
before normalizing.

**Compilation errors after pulling**
Run `mise run reset` to clean and reinstall everything.
