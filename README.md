# omop-phenotype-pipeline

**Benchmarking LLM-assisted OMOP phenotype curation against expert-curated gold standards from the OHDSI Phenotype Library, with concept-level *and* patient-level evaluation.**

An R-based pipeline that asks an LLM (Claude Opus 4.6 and Gemini 2.5 Flash) to produce a clinical concept set from a plain-language physician brief, resolves the LLM's concept *names* into verified OMOP standard concept_ids via PostgreSQL, expands via `concept_ancestor`, and scores the result against both (1) the gold concept set and (2) the gold patient cohort identified in a real OMOP CDM database (MIMIC-IV).

---

## Headline result

5 phenotypes × 2 LLMs × 3 trials × 5,000-patient MIMIC-IV subset:

| Metric | Concept-level F1 (ancestor-aware) | **Patient-level F1** |
|---|---:|---:|
| Mean across 30 cells | 0.248 | **0.642** |
| Best cell | trd × Claude: 0.624 | **t2dm × Claude: 0.980** |
| Patient recall (mean) | — | **0.886** |

**Concept-level F1 understates clinical utility by ~2.6×.** Two methodology improvements — phenotype-aware lab-concept filtering and physician-brief enrichment — lifted mean Patient F1 from 0.457 to 0.642 (+40% relative). See [docs/OMOP_LLM_Pipeline_Rationale.html](docs/OMOP_LLM_Pipeline_Rationale.html) for the framing and worked examples.

---

## How it works

```
┌─────────────────────────────────────────────────────────────────────────┐
│ INPUT:   plain-language physician brief (e.g. "Type 2 diabetes ...")   │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ PHASE 1 — LLM generates concept NAMES (Claude / Gemini)                 │
│           Strict rule: NEVER concept_ids (validated by response_parser) │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ PHASE 2 — SQL 5-tier cascade resolves NAMES → standard concept_ids      │
│           Tier 1 exact name → Tier 5 fuzzy LIKE, domain-filtered        │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ PHASE 3 — Ancestor expansion via vocab.concept_ancestor                 │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ PHASE 4 — Concept-level evaluation: precision, recall, F1, F1_aa        │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│ PHASE 5 — Patient-level evaluation against MIMIC-IV (or other OMOP CDM) │
│           patient_precision, patient_recall, patient_f1                 │
└─────────────────────────────────────────────────────────────────────────┘
```

Module map: [R/phase1_llm/](R/phase1_llm/), [R/phase2_lookup/](R/phase2_lookup/), [R/phase3_expansion/](R/phase3_expansion/), [R/evaluation/](R/evaluation/), orchestrator [R/pipeline.R](R/pipeline.R).

---

## Prerequisites

| Requirement | Version tested |
|---|---|
| R | ≥ 4.4 (tested with 4.6.0) |
| RStudio | optional but recommended |
| PostgreSQL | ≥ 14 (tested with 18) |
| OMOP Standard Vocabulary | loaded into a `vocab` schema (download from [Athena](https://athena.ohdsi.org)) |
| OMOP CDM clinical data | populated `condition_occurrence`, `drug_exposure`, `measurement`, `procedure_occurrence`, `observation` tables — e.g. MIMIC-IV (see Data Availability below) |
| Anthropic API key | https://console.anthropic.com |
| Google Gemini API key | https://aistudio.google.com |

All R package dependencies are pinned in [renv.lock](renv.lock).

---

## Quick start

1. **Clone and open:**
   ```bash
   git clone https://github.com/<your-org>/omop-phenotype-pipeline.git
   cd omop-phenotype-pipeline
   ```
   Open `omop-phenotype-pipeline.Rproj` in RStudio (auto-activates renv).

2. **Restore the R environment:**
   ```r
   renv::restore()
   ```

3. **Configure secrets:** copy [.env.example](.env.example) → `.env` and fill in:
   ```
   ANTHROPIC_API_KEY=sk-ant-...
   GEMINI_API_KEY=AI...
   DB_HOST=localhost
   DB_PORT=5432
   DB_NAME=<your_omop_database>
   DB_USER=<your_user>
   DB_PASSWORD=<your_password>
   ```

4. **Configure schemas** in [config/db_config.yaml](config/db_config.yaml) (lines 10-11):
   ```yaml
   vocab_schema: vocab          # OMOP standard vocabulary
   cdm_schema:   mimiciv_omop   # the CDM clinical schema you want to evaluate against
   ```

5. **Extract gold standards** (one-time, requires OHDSI's [PhenotypeLibrary](https://github.com/OHDSI/PhenotypeLibrary) R package):
   ```r
   source("scripts/extract_gold_standards.R")
   ```
   Writes 5 JSONs to `data/gold_standards/`.

6. **Run the full benchmark:**
   ```r
   source("scripts/run_pipeline.R")
   ```
   Writes `data/results/pipeline_summary.csv`, per-cell expanded concept sets to `data/results/expanded/`, and per-cell patient classifications to `data/results/patients/`. Expected wall time ≈ 40-60 minutes, expected API cost ≈ $3-4 USD at current Claude Opus pricing.

7. **Run a single cell** (smoke test, ~$0.50):
   ```bash
   Rscript scripts/run_pipeline.R --phenotype t2dm --model claude_opus_4_6
   ```

---

## Reproducing the headline numbers

The `pipeline_summary_mimic5k_gamma.csv` snapshot committed to this repo was produced by the configuration in [config/db_config.yaml](config/db_config.yaml) with `cdm_schema: mimiciv_omop` pointing at a 5,000-patient subset of MIMIC-IV v3.1.

**LLM API non-determinism:** Even at the configured `temperature: 0.3`, the LLMs are non-deterministic. Re-running the benchmark will produce mean Patient F1 in the **0.60–0.68 range** (vs the snapshot's 0.642), with per-cell SDs as reported in the CSV. To reproduce *exact* numbers from a saved LLM output, the per-trial expanded concept sets in `data/results/expanded/` (gitignored — kept local) can be re-fed through Phases 2-5 without re-calling the LLM.

**5,000-patient MIMIC-IV subset:** see [docs/MIMIC_IV_ETL_blueprint.md](docs/MIMIC_IV_ETL_blueprint.md) for the step-by-step subsampling and OHDSI ETL workflow (~3-4 hours of mostly-waiting from a fresh MIMIC-IV download).

---

## Project structure

```
omop-phenotype-pipeline/
├── CLAUDE.md                       Agent / contributor entry point
├── README.md                       (this file)
├── omop-phenotype-pipeline.Rproj   open in RStudio
├── renv.lock                       pinned R package versions
├── .env.example                    template; copy to .env with real credentials
│
├── config/
│   └── db_config.yaml              PostgreSQL + LLM model + phenotype config
│
├── data/
│   ├── physician_briefs/           plain-language phenotype descriptions (input)
│   ├── gold_standards/             OHDSI cohort concept-set JSONs (input)
│   └── results/                    pipeline output CSVs (most gitignored)
│
├── R/
│   ├── pipeline.R                  orchestrator
│   ├── phase1_llm/                 prompt → LLM call → JSON parse
│   ├── phase2_lookup/              5-tier SQL cascade name → concept_id
│   ├── phase3_expansion/           ancestor + cross-vocab expansion
│   └── evaluation/                 concept scorer + patient_eval
│
├── scripts/
│   ├── extract_gold_standards.R    one-time gold extraction from OHDSI library
│   └── run_pipeline.R              main entry point
│
├── docs/
│   ├── OMOP_LLM_Pipeline_Rationale.html    why this design, worked examples
│   └── MIMIC_IV_ETL_blueprint.md           how to build the 5K MIMIC subset
│
├── reports/                        Rmd analysis notebooks
└── tests/                          unit tests (concept_lookup, scorer)
```

---

## Data availability

- **OHDSI Phenotype Library** cohort definitions (cohortIds 288, 1103, 736, 253, 1009): public, fetched via OHDSI's `PhenotypeLibrary` R package. The per-phenotype seed concept sets are saved as JSON in `data/gold_standards/` (committed to this repo).
- **OMOP Standard Vocabulary** (CONCEPT.csv, CONCEPT_ANCESTOR.csv, etc.): available from [Athena](https://athena.ohdsi.org) per Athena's terms of use; **not redistributed in this repo**.
- **MIMIC-IV v3.1**: requires PhysioNet credentialing — [physionet.org/content/mimiciv/3.1/](https://physionet.org/content/mimiciv/3.1/). **Not redistributed in this repo.** The committed `pipeline_summary_mimic5k_gamma.csv` contains only aggregated metrics and counts; no MIMIC patient identifiers or row-level data are committed.
- **MIMIC-IV demo (OMOP CDM v0.9, 100 patients)**: also gated behind PhysioNet credentialing — [physionet.org/content/mimic-iv-demo-omop](https://physionet.org/content/mimic-iv-demo-omop/0.9/). Used during development; not redistributed.

---

## Configuration knobs worth knowing

In [config/db_config.yaml](config/db_config.yaml):

| Knob | Default | Effect |
|---|---|---|
| `pipeline.trials_per_cell` | 3 | Number of LLM trials per (phenotype × model) cell |
| `pipeline.max_concepts_per_phenotype` | 100 | Target LLM concept budget |
| `llm.models[*].temperature` | 0.3 | Sampling temperature; set to `~` (null) for models that deprecate it |
| `llm.models[*].max_output_tokens` | 16384 | Max output budget; raise for very long enumerations |
| `phenotypes[*].exclude_labs_in_patient_query` | true / false (per phenotype) | If true, drop Measurement-domain concepts from the patient query (avoids over-flagging from routine lab orders) |

---

## License

Apache 2.0 — see [LICENSE](LICENSE).

---

## Citation

```bibtex
@misc{omop_phenotype_pipeline_2026,
  title  = {Patient-level evaluation of LLM-assisted OMOP phenotype curation},
  author = {Tavakoli, Hamid},
  year   = {2026},
  url    = {https://github.com/<your-org>/omop-phenotype-pipeline},
  note   = {OHDSI Symposium submission}
}
```

(Update once a DOI is minted — Zenodo integration recommended for a permanent identifier.)

---

## Acknowledgments

- [OHDSI](https://www.ohdsi.org/) for the Common Data Model, standard vocabulary, and Phenotype Library
- [PhysioNet / MIT-LCP](https://physionet.org/) for MIMIC-IV
- [Anthropic](https://www.anthropic.com/) and [Google](https://deepmind.google/) for LLM API access

---

## Contact

For questions about the methodology or to discuss collaboration on extending this benchmark, please open an issue on the repository or contact the author.
