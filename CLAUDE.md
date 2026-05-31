# OMOP Phenotype Pipeline — Claude Code Instructions

## What This Project Is

An **R-based pipeline** that benchmarks LLM-assisted OMOP CDM phenotype curation
against gold-standard concept sets from the OHDSI Phenotype Library.

**Core idea:** LLMs generate clinical concept *names* only. Real PostgreSQL vocabulary
tables resolve those names to verified concept_ids via SQL. This mirrors how a real
medical coder works — they never memorise concept_ids, they look them up in ATHENA/SQL.

**Language:** R (all source code in `R/`). The `src/` folder is legacy — ignore it.

**Models compared:**
- Claude Opus 4.6 (`claude-opus-4-6`) via Anthropic API
- Gemini 2.5 Flash (`gemini-2.5-flash`) via Google API

**Five phenotypes (original):**
| Key | Name | cohortId | Gold concepts |
|-----|------|----------|--------------|
| t2dm | Type 2 Diabetes Mellitus | 288 | 18 |
| cardiac_valve_af | Cardiac Valve Surgery + New-onset AF | 11103 | 194 |
| acute_liver_injury | Acute Liver Injury excl. Viral Hepatitis | 4736 | 36 |
| drug_pancreatitis | Drug-Induced Acute Pancreatitis | 3957 | 32 |
| trd | Treatment-Resistant Depression | 11009 | 70 |

New phenotypes can be added — see "Adding a New Phenotype" below.

---

## Project Status

- [x] Project structure and all R source files created
- [x] Config and env templates ready
- [x] Physician brief for T2DM written (template for others)
- [ ] Fill `config/db_config.yaml` with your PostgreSQL credentials
- [ ] Copy `.env.example` → `.env` and add API keys
- [ ] Run `scripts/extract_gold_standards.R` to download gold standards from OHDSI
- [ ] Write physician briefs for P2–P5 (see `data/physician_briefs/`)
- [ ] Run `scripts/run_pipeline.R` for baseline results
- [ ] Iterate and add new phenotypes

---

## Repository Structure

```
omop-phenotype-pipeline/
├── CLAUDE.md                          ← YOU ARE HERE — start here
├── omop-phenotype-pipeline.Rproj      ← Open this in RStudio
├── .Rprofile                          ← renv auto-activation
├── .env.example                       ← Copy to .env, add API keys
│
├── config/
│   └── db_config.yaml                 ← PostgreSQL + LLM + phenotype settings
│
├── data/
│   ├── gold_standards/                ← JSON files (from extract_gold_standards.R)
│   ├── physician_briefs/              ← Plain-language phenotype descriptions
│   │   ├── p01_t2dm_brief.txt         ← COMPLETE — use as template for others
│   │   ├── p02_cardiac_valve_af_brief.txt
│   │   ├── p03_acute_liver_injury_brief.txt
│   │   ├── p04_drug_pancreatitis_brief.txt
│   │   └── p05_trd_brief.txt
│   └── results/                       ← Pipeline output CSVs
│
├── R/
│   ├── pipeline.R                     ← MAIN ORCHESTRATOR — source this to run
│   ├── phase1_llm/
│   │   ├── prompt_builder.R           ← Builds LLM prompt from physician brief
│   │   ├── llm_client.R               ← Claude + Gemini API calls
│   │   └── response_parser.R          ← Parses LLM JSON → data frame
│   ├── phase2_lookup/
│   │   ├── db_connector.R             ← PostgreSQL DBI connection
│   │   ├── concept_lookup.R           ← 5-tier SQL cascade: name → concept_id
│   │   └── lookup_report.R            ← Resolved vs unresolved summary
│   ├── phase3_expansion/
│   │   ├── ancestor_expansion.R       ← CONCEPT_ANCESTOR descendant traversal
│   │   └── crossvocab_mapping.R       ← CONCEPT_RELATIONSHIP cross-vocab mapping
│   └── evaluation/
│       ├── scorer.R                   ← Precision / Recall / F1 / Jaccard
│       └── error_analysis.R           ← FP/FN classification by workflow phase
│
├── scripts/
│   ├── extract_gold_standards.R       ← Downloads gold standards from OHDSI (run once)
│   └── run_pipeline.R                 ← Entry point to run all phenotypes × all models
│
├── reports/
│   ├── 01_gold_standard_exploration.Rmd
│   └── 03_results_comparison.Rmd
│
└── tests/
    ├── test_concept_lookup.R
    └── test_scorer.R
```

---

## Quick Start (After Filling Config)

```r
# 1. Open omop-phenotype-pipeline.Rproj in RStudio

# 2. Install dependencies (first time only)
install.packages("renv")
renv::restore()

# 3. Extract gold standards (requires PhenotypeLibrary from OHDSI)
source("scripts/extract_gold_standards.R")

# 4. Run the full pipeline (all 5 phenotypes × 2 models)
source("scripts/run_pipeline.R")

# 5. View results
results <- readr::read_csv("data/results/pipeline_summary.csv")
print(results[, c("phenotype", "model", "f1", "f1_ancestor", "resolution_rate")])
```

---

## Key Design Rules — Never Break These

1. **The LLM must NEVER output concept_ids.** The `response_parser.R` validates this
   and stops with an error if any integers resembling concept_ids appear in the output.

2. **Only `standard_concept = 'S'` AND `invalid_reason IS NULL`** concepts enter the
   final concept set. Enforced in `concept_lookup.R`.

3. **`is_excluded = TRUE` only when the physician brief explicitly says** "exclude",
   "no prior", "without", or "not". Never for differential-diagnosis reasoning.

4. **Every concept_id must be verified** against `vocab.concept` before use. Any ID
   not found in the table is dropped and logged as an error.

---

## OMOP Vocabulary Tables Used

All tables live in the schema defined by `vocab_schema` in `db_config.yaml`.

| Table | Used in Phase | Purpose |
|-------|--------------|---------|
| `concept` | Phase 2 | Name → concept_id lookup; standard concept filter |
| `concept_synonym` | Phase 2 | Synonym name lookup (tiers 2 & 4) |
| `concept_ancestor` | Phase 3 | Descendant expansion |
| `concept_relationship` | Phase 3 | Cross-vocabulary mapping (`Maps to`) |

---

## Evaluation Metrics Produced

| Metric | Description |
|--------|-------------|
| `precision` | Exact: \|predicted ∩ gold\| / \|predicted\| |
| `recall` | Exact: \|predicted ∩ gold\| / \|gold\| |
| `f1` | Harmonic mean of exact precision and recall |
| `f1_ancestor` | Ancestor-aware F1 — credits descendants of gold concepts |
| `resolution_rate` | % of LLM concept names resolved by SQL lookup |

---

## Adding a New Phenotype

1. Write `data/physician_briefs/pXX_name_brief.txt`
2. Add the cohort_id to `scripts/extract_gold_standards.R` and re-run it
3. Add an entry under `phenotypes:` in `config/db_config.yaml`
4. Run `source("scripts/run_pipeline.R")`

---

## R Package Dependencies

```r
# Core
library(DBI)           # database abstraction
library(RPostgres)     # PostgreSQL driver
library(httr2)         # HTTP calls to LLM APIs
library(jsonlite)      # JSON parsing
library(yaml)          # config reading
library(dplyr)         # data manipulation
library(tidyr)         # reshaping
library(purrr)         # functional iteration
library(glue)          # SQL string interpolation
library(readr)         # CSV I/O
library(dotenv)        # .env file loading

# OHDSI (for gold standard extraction)
library(PhenotypeLibrary)   # remotes::install_github("OHDSI/PhenotypeLibrary")
library(CirceR)             # remotes::install_github("OHDSI/CirceR")

# Reporting
library(ggplot2)
library(knitr)
library(rmarkdown)

# Testing
library(testthat)
```

---

## Reference Documents

| Document | Location |
|----------|----------|
| Project rationale & worked examples (HTML) | `docs/OMOP_LLM_Pipeline_Rationale.html` |
| Full project plan | `../NEW_PROJECT_PLAN_OMOP_LLM_Pipeline.md` |
| OMOP workflow reference | `../OMOP_Phenotype_Curation_Workflow.md` |
| OHDSI Phenotype Library | https://ohdsi.github.io/PhenotypeLibrary/ |
| ATHENA vocabulary browser | https://athena.ohdsi.org |
| Book of OHDSI — Vocabularies | https://ohdsi.github.io/TheBookOfOhdsi/StandardizedVocabularies.html |
| Anthropic API docs | https://docs.anthropic.com/en/api/messages |
| Gemini API docs | https://ai.google.dev/api/generate-content |

---

## Coding Behaviour Guidelines

*Sourced from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills/blob/main/CLAUDE.md).
These guidelines bias toward caution over speed. For trivial tasks, use judgment.*

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing R style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write `testthat` tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

*These guidelines are working if:* fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
