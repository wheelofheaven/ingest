# PDF Pipeline

PDF-to-structured-JSON pipeline for the Wheel of Heaven [data-library](https://github.com/wheelofheaven/data-library). Extracts text from religious/philosophical PDFs via GLM-OCR, structures it into chapters and paragraphs with speaker attribution, and exports to the data-library schema format.

## Architecture

```
PDF Input → GLM-OCR Extraction → Rule-Based Structuring → LLM Refinement → data-library JSON
```

Two interfaces:
- **CLI** (`mix pdf.ingest`) for scripted batch processing
- **Phoenix LiveView** web UI for interactive review, correction, and export

## Setup

```bash
mix setup
```

### Environment Variables

```bash
export ZAI_API_KEY="your-glm-ocr-api-key"        # Required for OCR
export ANTHROPIC_API_KEY="your-anthropic-api-key"  # Required for LLM refinement
export DATA_LIBRARY_PATH="../data-library"         # Output directory
```

## CLI Usage

```bash
mix pdf.ingest path/to/book.pdf \
  --slug the-book-which-tells-the-truth \
  --code TBWTT \
  --lang fr \
  --title "Le Livre Qui Dit la Vérité" \
  --year 1973 \
  --rules raelian
```

### Options

| Flag | Required | Description |
|------|----------|-------------|
| `--slug` | Yes | Book slug (kebab-case) |
| `--code` | Yes | Book code (uppercase, e.g. "TBWTT") |
| `--lang` | Yes | Primary language (ISO 639-1) |
| `--rules` | No | Rule profile: `default`, `raelian` |
| `--output` | No | Output directory |
| `--title` | No | Book title in primary language |
| `--year` | No | Publication year |
| `--no-refine` | No | Skip LLM refinement |

## Web UI

```bash
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) to:
- Upload PDFs and start ingestion jobs
- Review OCR output alongside structured JSON
- Edit paragraphs, fix speakers, merge/split content
- Validate against schema and export to data-library

## Pipeline Stages

1. **OCR Extraction** — Sends PDF to GLM-OCR API, returns markdown text
2. **Rule-Based Parsing** — Splits text into chapters/paragraphs using configurable regex rules
3. **LLM Refinement** (optional) — Sends low-confidence paragraphs to Claude for speaker attribution
4. **Validation & Export** — Validates against JSON schema, writes to data-library format

## Rule Profiles

Rules live in `priv/rules/*.json`. Available profiles:
- `default` — Generic chapter/paragraph patterns
- `raelian` — Raëlian-specific patterns (CHAPITRE headings, known speakers)

## Output Format

Matches the data-library schema. Small books export as single JSON file; larger books split into `_meta.json` + `chapter-N.json` files.

## Tests

```bash
mix test
```

## License

CC0-1.0
