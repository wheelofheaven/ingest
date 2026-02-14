# Pipeline Workflow

## Overview

The PDF Pipeline converts source PDFs into structured JSON that matches the
[data-library](https://github.com/wheelofheaven/data-library) schema. The
pipeline is split into four discrete stages. Each stage produces a persisted
artifact under `_work/{slug}/`, so you can inspect, edit, or re-run any
individual stage without starting over.

## Stage Diagram

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │                        PDF Pipeline Stages                           │
 └──────────────────────────────────────────────────────────────────────┘

    PDF file                    _work/{slug}/
   ┌──────────┐
   │ book.pdf │
   └────┬─────┘
        │
        ▼
 ┌──────────────┐         ┌──────────────────┐
 │   Stage 1    │         │                  │
 │    OCR       │────────▶│    ocr.md        │   Raw extracted text
 │  (GLM-OCR)   │         │                  │   (markdown format)
 └──────────────┘         └────────┬─────────┘
                                   │
                                   ▼
 ┌──────────────┐         ┌──────────────────┐
 │   Stage 2    │         │                  │
 │  Normalize   │────────▶│   book.json      │   Structured chapters,
 │ (rule-based) │         │                  │   paragraphs, speakers
 └──────────────┘         └────────┬─────────┘
                                   │
                                   ▼
 ┌──────────────┐         ┌──────────────────┐
 │   Stage 3    │         │                  │
 │  Translate   │────────▶│ book_translated  │   i18n slots filled
 │   (LLM)      │         │     .json        │   for target languages
 └──────────────┘         └────────┬─────────┘
                                   │
                                   ▼
 ┌──────────────┐         ┌──────────────────┐
 │   Stage 4    │         │  data-library/   │
 │   Export     │────────▶│  {slug}/         │   Final JSON matching
 │              │         │  {slug}.json     │   data-library schema
 └──────────────┘         └──────────────────┘
```

## Data Flow

```
                        ┌─────────────────────┐
                        │   Sidecar Metadata  │
                        │   book.json         │
                        │  (slug, code, lang) │
                        └─────────┬───────────┘
                                  │
  book.pdf ──▶ GLM-OCR API ──▶ ocr.md ──▶ Rule Engine ──▶ book.json
                  (z.ai)           │         │                │
                                   │    ┌────┘                │
                                   │    │  Chapter patterns   │
                                   │    │  Paragraph splits   │
                                   │    │  Speaker detection  │
                                   │    │  Text cleanup       │
                                   │    └─────────────────────│
                                   │                          │
                                   │    ┌─────────────────────┘
                                   │    │
                                   │    ▼
                                   │  book.json ──▶ Translator ──▶ book_translated.json
                                   │                  (z.ai)              │
                                   │                                      │
                                   │                                      ▼
                                   │                            Export ──▶ data-library/
                                   │                                      {slug}.json
                                   │                                       or
                                   │                                      {slug}/
                                   │                                        _meta.json
                                   │                                        chapter-1.json
                                   │                                        chapter-2.json
                                   │                                        ...
                                   │
                                   ▼
                            (inspect/edit at any point)
```

## Stages in Detail

### Stage 1 &mdash; OCR

Sends the PDF to the [GLM-OCR](https://open.bigmodel.cn/) API (`api.z.ai`)
and saves the raw extracted text as markdown.

```
mise run ocr -- path/to/book.pdf --slug my-book
```

| Input           | Output                      |
|-----------------|-----------------------------|
| `book.pdf`      | `_work/{slug}/ocr.md`       |

The OCR model (`glm-ocr`) handles complex layouts including multi-column text,
tables (as HTML), headers/footers, and footnotes. The output is UTF-8 markdown.

### Stage 2 &mdash; Normalize

Applies rule-based parsing to split the raw text into chapters, paragraphs,
and speaker attributions. Optionally runs LLM refinement on low-confidence
paragraphs.

```
mise run normalize -- --slug my-book --code MB --lang fr --rules raelian
```

| Input                     | Output                     |
|---------------------------|----------------------------|
| `_work/{slug}/ocr.md`     | `_work/{slug}/book.json`   |

Rule profiles are loaded from `priv/rules/{profile}.json`. Currently available:
- `default` &mdash; Generic chapter/paragraph patterns
- `raelian` &mdash; Patterns for Raelian texts (CHAPITRE headings, known speakers)

The `--refine` flag sends ambiguous paragraphs to the LLM for speaker
identification. Without it, only rule-based heuristics are used.

### Stage 3 &mdash; Translate

Translates the structured book into target languages using the z.ai chat API.
Religious/philosophical terms (Elohim, Yahweh, etc.) are preserved untranslated.

```
mise run translate -- --slug my-book
mise run translate -- --slug my-book --langs en,de,es
```

| Input                     | Output                                |
|---------------------------|---------------------------------------|
| `_work/{slug}/book.json`  | `_work/{slug}/book_translated.json`   |

Translation is batched (15 paragraphs per API call) and covers both paragraph
text and chapter titles. Default target languages: `en`, `fr`, `de`, `es`,
`ru`, `ja`, `zh`.

### Stage 4 &mdash; Export

Writes the final JSON to the data-library directory. Chooses single-file or
split-file format depending on the output size (threshold: 100 KB).

```
mise run export -- --slug my-book
mise run export -- --slug my-book --output ../data-library
```

| Input                                           | Output                              |
|-------------------------------------------------|-------------------------------------|
| `_work/{slug}/book.json` or `book_translated.json` | `data-library/{slug}.json` or `data-library/{slug}/` |

## Full Pipeline (All Stages)

To run everything in one go:

```
mise run curator -- path/to/book.pdf --slug my-book --code MB --lang fr --rules raelian
```

Or with translation:

```
mise run curator -- path/to/book.pdf --slug my-book --code MB --lang fr --translate --langs en,de
```

## Re-running Stages

Each stage checks for existing artifacts and skips if output already exists.
Use `--force` to re-run:

```
mise run ocr       -- book.pdf --slug my-book --force
mise run normalize -- --slug my-book --force
mise run translate -- --slug my-book --force
```

## Inspecting Artifacts

Intermediate results live in `_work/{slug}/`:

```
_work/
  the-book-which-tells-the-truth/
    ocr.md                    # Raw OCR output (readable markdown)
    book.json                 # Structured JSON (chapters, paragraphs)
    book_translated.json      # With i18n slots filled
```

Open `book.json` in any editor to review the structure, fix speaker
attributions, or adjust chapter boundaries before proceeding to the next stage.
