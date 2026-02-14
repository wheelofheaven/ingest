# Architecture

## System Context

```
 ┌──────────────────────────────────────────────────────────────┐
 │                     Wheel of Heaven                          │
 │                                                              │
 │  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐  │
 │  │ data-sources │   │ curator│   │  data-library    │  │
 │  │   (private)  │──▶│  (this repo) │──▶│   (public)       │  │
 │  │              │   │              │   │                  │  │
 │  │  Source PDFs │   │  OCR, parse, │   │  Structured JSON │  │
 │  │  + metadata  │   │  translate,  │   │  for the website │  │
 │  │              │   │  export      │   │                  │  │
 │  └──────────────┘   └──────┬───────┘   └──────────────────┘  │
 │                            │                                 │
 │                     ┌──────┴───────┐                         │
 │                     │   z.ai API   │                         │
 │                     │  (GLM-OCR +  │                         │
 │                     │   chat LLM)  │                         │
 │                     └──────────────┘                         │
 └──────────────────────────────────────────────────────────────┘
```

curator sits between raw source material and the public data-library.
It uses the z.ai API for both OCR extraction and LLM-powered tasks
(refinement, translation).

## Tech Stack

| Layer         | Technology                                          |
|---------------|-----------------------------------------------------|
| Language      | Elixir 1.19 / Erlang/OTP 28                         |
| Web framework | Phoenix 1.8 + LiveView 1.1                          |
| HTTP client   | Req                                                 |
| JSON          | Jason                                               |
| Validation    | ex_json_schema                                      |
| HTML parsing  | Floki (for OCR table output)                        |
| Tooling       | mise (versions, env, task runner)                   |

## Project Structure

```
curator/
├── config/
│   ├── config.exs               # Compile-time config
│   ├── dev.exs                  # Dev settings
│   ├── test.exs                 # Test settings
│   └── runtime.exs              # Runtime config (env vars, API keys)
│
├── lib/
│   ├── curator/
│   │   ├── application.ex       # OTP supervision tree
│   │   ├── pipeline.ex          # Top-level orchestrator
│   │   │
│   │   ├── stages/              # Discrete pipeline stages
│   │   │   ├── work_dir.ex      #   _work/ directory management
│   │   │   ├── ocr.ex           #   Stage 1: PDF → text
│   │   │   ├── normalize.ex     #   Stage 2: text → structured JSON
│   │   │   ├── translate.ex     #   Stage 3: fill i18n slots
│   │   │   └── export.ex        #   Stage 4: write to data-library
│   │   │
│   │   ├── ocr/                 # GLM-OCR API integration
│   │   │   ├── client.ex        #   HTTP client for api.z.ai
│   │   │   └── response.ex      #   Response parsing & normalization
│   │   │
│   │   ├── parser/              # Rule-based text structuring
│   │   │   ├── rule_engine.ex   #   Orchestrator: loads rules, runs stages
│   │   │   ├── text_utils.ex    #   Unicode normalization, cleanup
│   │   │   └── rules/
│   │   │       ├── chapter_rules.ex    # Chapter boundary detection
│   │   │       ├── paragraph_rules.ex  # Paragraph splitting + confidence
│   │   │       └── speaker_rules.ex    # Speaker attribution
│   │   │
│   │   ├── refiner/             # LLM-assisted refinement
│   │   │   ├── strategy.ex      #   Decides what needs LLM vs rules
│   │   │   ├── llm_client.ex    #   Sends batches to LLM
│   │   │   └── prompts.ex       #   Prompt builders
│   │   │
│   │   ├── translator.ex        # LLM-based translation
│   │   │
│   │   ├── llm/                 # Unified LLM client
│   │   │   └── client.ex        #   z.ai (default) + Anthropic fallback
│   │   │
│   │   ├── schema/              # Data structures
│   │   │   ├── book.ex          #   Book (top-level, matches data-library)
│   │   │   ├── chapter.ex       #   Chapter with i18n
│   │   │   ├── paragraph.ex     #   Paragraph with speaker + i18n
│   │   │   ├── catalog_entry.ex #   Catalog metadata
│   │   │   └── validator.ex     #   JSON Schema validation
│   │   │
│   │   ├── export/              # Output writers
│   │   │   ├── data_library.ex  #   Orchestrator (single vs split)
│   │   │   ├── single_file.ex   #   {slug}.json (< 100 KB)
│   │   │   └── split_file.ex    #   {slug}/_meta.json + chapter-N.json
│   │   │
│   │   └── store/
│   │       └── job.ex           #   ETS-based job state tracking
│   │
│   ├── curator_web/
│   │   ├── router.ex            # Routes
│   │   └── live/
│   │       ├── dashboard_live.ex  # Upload, job tracking, stage status
│   │       ├── review_live.ex     # Side-by-side OCR vs structured view
│   │       ├── editor_live.ex     # Inline paragraph/speaker editing
│   │       └── export_live.ex     # Preview, validate, download
│   │
│   └── mix/tasks/               # CLI entry points
│       ├── pdf.ocr.ex           #   mix pdf.ocr
│       ├── pdf.normalize.ex     #   mix pdf.normalize
│       ├── pdf.translate.ex     #   mix pdf.translate
│       ├── pdf.export.ex        #   mix pdf.export
│       └── curator.run.ex        #   mix curator.run (full pipeline)
│
├── priv/
│   ├── rules/                   # Rule config files (JSON)
│   │   ├── default.json         #   Generic patterns
│   │   └── raelian.json         #   Raelian-specific patterns
│   └── prompts/                 # LLM prompt templates (EEx)
│       ├── identify_speakers.eex
│       ├── refine_paragraphs.eex
│       └── structure_chapters.eex
│
├── test/                        # Test suite
├── docs/                        # This documentation
├── _work/                       # Intermediate artifacts (gitignored)
├── mise.toml                    # Tool versions + task definitions
├── .env                         # API keys (gitignored)
└── .env.example                 # Template for .env
```

## Module Dependency Graph

```
                    Mix Tasks
                 (pdf.ocr, pdf.normalize, ...)
                        │
                        ▼
                ┌───────────────┐
                │   Pipeline    │   Top-level orchestrator
                │  (pipeline.ex)│   Wires stages together
                └───────┬───────┘
                        │
          ┌─────────────┼─────────────┐
          │             │             │
          ▼             ▼             ▼
    ┌───────────┐ ┌───────────┐ ┌───────────┐
    │ Stages.OCR│ │Stages.    │ │Stages.    │
    │           │ │Normalize  │ │Translate  │───▶ Translator
    └─────┬─────┘ └─────┬─────┘ └─────┬─────┘
          │             │             │
          ▼             ▼             │
    ┌───────────┐ ┌───────────┐       │
    │ OCR.Client│ │  Parser.  │       │
    │ OCR.      │ │RuleEngine │       │
    │ Response  │ └─────┬─────┘       │
    └─────┬─────┘       │             │
          │       ┌─────┼─────┐       │
          │       ▼     ▼     ▼       │
          │  Chapter  Para  Speaker   │
          │  Rules    Rules Rules     │
          │                           │
          │     ┌────────────┐        │
          │     │  Refiner   │        │
          │     │  Strategy  │        │
          │     │  LlmClient │        │
          │     │  Prompts   │        │
          │     └──────┬─────┘        │
          │            │              │
          └────────────┼──────────────┘
                       ▼
                ┌──────────────┐
                │  LLM.Client  │   Unified HTTP client
                │  (z.ai +     │   for all LLM calls
                │   Anthropic) │
                └──────────────┘

  Schema structs (Book, Chapter, Paragraph) are used across all layers.
  WorkDir manages artifact persistence for all stages.
```

## Key Design Decisions

### Discrete Stages with Artifacts

Each pipeline stage reads from and writes to the `_work/{slug}/` directory.
This design enables:

- **Inspectability** &mdash; Open `ocr.md` or `book.json` in any editor to
  review intermediate results
- **Idempotency** &mdash; Stages skip if output already exists (override with
  `--force`)
- **Manual correction** &mdash; Edit `book.json` by hand (fix speakers, merge
  paragraphs) then continue to the next stage
- **Selective re-runs** &mdash; Re-run only translation without re-doing OCR

### Unified LLM Client

`Curator.LLM.Client` provides a single interface for all LLM calls.
It supports two providers:

| Provider  | API                     | Model         | Usage                          |
|-----------|-------------------------|---------------|--------------------------------|
| z.ai      | OpenAI-compatible       | `glm-4-plus`  | Default for all LLM tasks      |
| Anthropic | Native Messages API     | `claude-sonnet-4-5-20250929`  | Optional fallback              |

The provider is auto-selected based on which API key is configured.
z.ai is preferred because it also provides the OCR API, so a single key
covers the entire pipeline.

### Rule-Based Parsing with LLM Refinement

The parser uses a two-tier approach:

1. **Rule engine** (fast, free) &mdash; Regex-based chapter detection,
   paragraph splitting, known speaker patterns. Assigns a confidence score
   to each paragraph.
2. **LLM refinement** (optional, costs API credits) &mdash; Only invoked for
   paragraphs below the confidence threshold (default: 0.7). Handles
   ambiguous speaker attribution and uncertain paragraph boundaries.

This hybrid approach minimizes API costs while maintaining quality.

### Configurable Rule Profiles

Rule profiles are JSON files in `priv/rules/`. Each profile defines:

- `chapter_patterns` &mdash; Regex patterns for chapter headings
- `paragraph_separator` &mdash; How to split paragraphs (default: `\n\n`)
- `speaker_patterns` &mdash; Known speakers and dialogue markers
- `strip_patterns` &mdash; Patterns to remove (page numbers, headers)
- `default_speaker` &mdash; Fallback speaker name

New profiles can be added for different book traditions without changing code.

### Export Format Selection

The export stage auto-selects the output format:

- **Single file** (`{slug}.json`) &mdash; When serialized JSON is under 100 KB
- **Split files** (`{slug}/_meta.json` + `chapter-N.json`) &mdash; When over
  100 KB, to keep individual files manageable for Git

Both formats conform to the data-library schema.

## Data Model

The internal data model mirrors the data-library JSON schema:

```
Book
├── slug: "the-book-which-tells-the-truth"
├── code: "TBWTT"
├── primaryLang: "fr"
├── titles: { "fr": "Le Livre...", "en": "The Book..." }
├── revision: 1
├── updated: "2026-02-14T..."
└── chapters: [
      Chapter
      ├── n: 1
      ├── title: "La Rencontre"
      ├── refId: "TBWTT-1"
      ├── i18n: { "en": "The Encounter", ... }
      └── paragraphs: [
            Paragraph
            ├── n: 1
            ├── text: "Le 13 décembre 1973..."
            ├── speaker: "Narrator"
            ├── refId: "TBWTT-1:1"
            ├── confidence: 0.95       (internal, not exported)
            └── i18n: { "en": "On December 13, 1973...", ... }
          ]
    ]
```

The `refId` format is `{CODE}-{CHAPTER}:{PARAGRAPH}` (e.g., `TBWTT-1:5`).
Confidence scores are used internally by the refiner but not exported.

## Supervision Tree

```
Curator.Application
└── Curator.Store.Job (GenServer)
      ETS table :curator_jobs
      Broadcasts via Phoenix.PubSub "jobs" topic
```

The job store tracks pipeline runs through the web UI. It uses ETS for
in-memory storage (no database required). Job state changes are broadcast
via PubSub so the LiveView dashboard updates in real-time.

## External APIs

### GLM-OCR (z.ai)

- **Endpoint:** `POST https://api.z.ai/api/paas/v4/layout_parsing`
- **Auth:** `Authorization: Bearer {ZAI_API_KEY}`
- **Input:** Base64-encoded PDF or URL
- **Output:** Extracted text in markdown format
- **Timeout:** 120 seconds (configurable)

### z.ai Chat (LLM)

- **Endpoint:** `POST https://api.z.ai/api/paas/v4/chat/completions`
- **Auth:** `Authorization: Bearer {ZAI_API_KEY}`
- **Model:** `glm-4-plus`
- **Used for:** Speaker identification, paragraph refinement, translation

### Anthropic (Fallback)

- **Endpoint:** `POST https://api.anthropic.com/v1/messages`
- **Auth:** `x-api-key: {ANTHROPIC_API_KEY}`
- **Model:** `claude-sonnet-4-5-20250929`
- **Used for:** Same tasks as z.ai, when `ANTHROPIC_API_KEY` is set and
  `ZAI_API_KEY` is not

## Web Interface

The Phoenix LiveView interface provides four views:

| Route                        | View            | Purpose                          |
|------------------------------|-----------------|----------------------------------|
| `/`                          | Dashboard       | Upload PDF, track jobs, stage status |
| `/review/:job_id`            | Review          | Side-by-side OCR vs structured   |
| `/review/:job_id/edit`       | Editor          | Edit paragraphs, speakers        |
| `/review/:job_id/export`     | Export          | Preview JSON, validate, download |

The web UI is complementary to the CLI. The CLI is better for scripted batch
processing; the web UI is better for interactive review and correction.
