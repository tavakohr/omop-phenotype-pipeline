# MIMIC-IV → OMOP CDM (5,000-patient subset) — Project Blueprint

**Use this as the seed CLAUDE.md (or equivalent) for a new Claude Code project.**

## Goal

Take the full MIMIC-IV v3.1 download (~9 GB compressed, ~60-80 GB uncompressed) and produce a PostgreSQL database with **a 5,000-patient subset converted to OMOP CDM v5.4**, ready for the OMOP-based LLM phenotype-curation pipeline to consume.

Why a subset: the full MIMIC-IV (~300,000 patients) requires ~120 GB of Postgres storage and 6-10 hours of ETL time. A 5,000-patient subset produces ~3 GB of storage, ~2 hours of work, and statistically meaningful patient counts for every common phenotype (~3K T2DM, ~350 cardiac valve + AF, ~750 acute liver injury, ~130 drug-induced pancreatitis, ~600 TRD).

## End state you'll have

| Schema | Contents | Approx size |
|---|---|---|
| `mimiciv_hosp` | Raw MIMIC hospital tables (patients, admissions, diagnoses_icd, prescriptions, labevents, etc.), filtered to 5,000 subjects | ~1.5 GB |
| `mimiciv_icu` | Raw MIMIC ICU tables (icustays, chartevents, inputevents, etc.), filtered to 5,000 subjects | ~1 GB |
| `mimiciv_omop` | OMOP CDM v5.4 tables (person, condition_occurrence, drug_exposure, etc.) produced by the OHDSI/MIMIC ETL | ~500 MB |
| `vocab` (reused, *do not recreate*) | OHDSI standard vocabulary | (already exists in your FHIR DB, ~30 GB) |

## Prerequisites — verify before starting

| Requirement | Check |
|---|---|
| PostgreSQL ≥14 with the existing `vocab` schema populated | `SELECT COUNT(*) FROM vocab.concept` → should return ~6M |
| Disk space ≥ 10 GB free in the Postgres data directory | Windows: right-click drive → Properties |
| MIMIC-IV v3.1 downloaded and extractable | Path to `mimiciv-3.1/` (or wherever you put it) |
| Python 3 with `pandas` and `psycopg2` (or any DB driver) | `pip install pandas psycopg2-binary` |
| R ≥ 4.4 with `DatabaseConnector`, `SqlRender`, `ETLSyntheaBuilder` (NOT used for MIMIC, but its sibling tools are) | Install fresh in the new project: `renv::install(...)` |
| Java 11+ | `java -version` — needed for OHDSI ETL R packages that wrap Java |
| Git | For cloning OHDSI/MIMIC repo |

## Step-by-step plan

### Phase 1 — Project setup (10 min)

1. Create the project folder (e.g., `C:\Users\<you>\Documents\mimic-iv-omop-etl`)
2. Initialize:
   - `git init`
   - `.gitignore` containing `*.csv`, `*.csv.gz`, `.env`, `renv/library/`, `renv/local/`, `data/extracted/`
   - `.env` with `DB_HOST`, `DB_PORT`, `DB_NAME` (= `FHIR` or similar), `DB_USER`, `DB_PASSWORD`
   - `config.yaml` with: `vocab_schema: vocab`, `mimic_hosp_schema: mimiciv_hosp`, `mimic_icu_schema: mimiciv_icu`, `cdm_schema: mimiciv_omop`, `sample_size: 5000`, `random_seed: 42`
3. Create folder structure: `data/extracted/`, `data/filtered/`, `scripts/`, `sql/`, `logs/`

### Phase 2 — Extract MIMIC-IV (30 min, ~70 GB temporary disk)

MIMIC-IV ships as `.csv.gz`. The OHDSI ETL needs uncompressed CSVs.

The download contains two folders:
- `hosp/` — patients, admissions, diagnoses_icd, procedures_icd, prescriptions, labevents, omr, transfers, services, microbiologyevents, pharmacy, poe, etc.
- `icu/` — icustays, chartevents (HUGE, ~30 GB uncompressed), inputevents, outputevents, procedureevents, datetimeevents, ingredientevents

**Two extraction strategies — pick one:**

**Strategy A (simpler, more disk):** Extract everything up front
- `gunzip -k *.csv.gz` in each folder (keeps the .gz)
- ~60-80 GB on disk afterwards
- Then proceed to filter

**Strategy B (smarter, less disk):** Stream-filter during the subsampling step
- Don't extract anything; let Python read directly from .csv.gz with `pandas.read_csv(..., compression='gzip', chunksize=100_000)`
- Outputs are pre-filtered small CSVs in `data/filtered/`
- Never have the full 60 GB on disk at once

**Recommend Strategy B.** Has the agent write a Python script for it (see Phase 4).

### Phase 3 — Pick the 5,000 subject_ids (5 min)

Load `patients.csv.gz` (small, ~10 MB), sample, save the chosen subject_ids.

```python
import pandas as pd
import random

random.seed(42)
patients = pd.read_csv('mimiciv-3.1/hosp/patients.csv.gz', compression='gzip')
print(f"Total patients in MIMIC-IV v3.1: {len(patients)}")
sample = patients.sample(n=5000, random_state=42)
sample[['subject_id']].to_csv('data/filtered/sample_subjects.csv', index=False)
print(f"Sampled {len(sample)} subjects, saved to data/filtered/sample_subjects.csv")
```

Save the seed (42 above) and exact sample list in the repo for reproducibility.

### Phase 4 — Filter each child table to the 5,000 subjects (30-60 min)

For each `.csv.gz` in `hosp/` and `icu/`, stream-read in chunks, keep only rows where `subject_id IN (sampled)`, write to `data/filtered/<table>.csv`.

```python
import pandas as pd
from pathlib import Path

SAMPLE_IDS = set(pd.read_csv('data/filtered/sample_subjects.csv')['subject_id'])
SRC_DIRS = ['mimiciv-3.1/hosp', 'mimiciv-3.1/icu']
OUT_DIR = Path('data/filtered'); OUT_DIR.mkdir(exist_ok=True)
CHUNK = 500_000  # adjust for memory

for src in SRC_DIRS:
    for f in Path(src).glob('*.csv.gz'):
        out_path = OUT_DIR / (f.stem.replace('.csv', '') + '.csv')  # strip both .csv and .gz
        if out_path.exists():
            print(f"skip (exists): {out_path}"); continue
        print(f"Filtering {f.name} ...")
        first = True
        rows_kept = 0
        for chunk in pd.read_csv(f, compression='gzip', chunksize=CHUNK, low_memory=False):
            if 'subject_id' in chunk.columns:
                filtered = chunk[chunk['subject_id'].isin(SAMPLE_IDS)]
            else:
                filtered = chunk  # tables without subject_id keep all rows (small reference tables)
            filtered.to_csv(out_path, mode='w' if first else 'a', header=first, index=False)
            first = False
            rows_kept += len(filtered)
        print(f"  → {out_path.name}: {rows_kept:,} rows kept")
```

Expected outputs roughly:
- `patients.csv` — 5,000 rows
- `admissions.csv` — ~25K rows
- `diagnoses_icd.csv` — ~250K rows
- `prescriptions.csv` — ~330K rows
- `labevents.csv` — ~5M rows (still the largest)
- `chartevents.csv` — ~5-10M rows
- Total filtered footprint: ~3-5 GB

### Phase 5 — Load filtered data into Postgres (15-30 min)

1. **Create schemas:**
   ```sql
   CREATE SCHEMA mimiciv_hosp;
   CREATE SCHEMA mimiciv_icu;
   ```

2. **Create DDL for MIMIC tables.** Use the official MIT-LCP scripts: clone [github.com/MIT-LCP/mimic-code](https://github.com/MIT-LCP/mimic-code), look in `mimic-iv/buildmimic/postgres/`. The files `create.sql` and `constraint.sql` are what you need.
   - **Important pitfall:** MIMIC uses **64-bit IDs**. The MIT-LCP scripts already use `BIGINT`; do NOT change them.
   - Run `create.sql` against your DB (it creates the tables with the right schemas — substitute your schema names if needed).

3. **Load each filtered CSV** with `\COPY`:
   ```sql
   \COPY mimiciv_hosp.patients FROM 'data/filtered/patients.csv' WITH (FORMAT csv, HEADER true, NULL '')
   ```
   Loop this in Python for all tables. Use **explicit column lists from each CSV header** to handle any column-order mismatches (lesson from prior work; see Pitfalls below).

4. **Apply constraints/indexes:** run `constraint.sql` from MIT-LCP repo. This creates PRIMARY KEYs and indexes — required for the OHDSI ETL to run efficiently.

### Phase 6 — Run the OHDSI MIMIC ETL (1-2 hours)

1. Clone the ETL repo: `git clone https://github.com/OHDSI/MIMIC.git ohdsi-mimic-etl`
2. Read its `README.md` and `etl/` folder. The ETL is SQL-based, driven from R.
3. **Required R packages** (install fresh in renv):
   - `DatabaseConnector`, `SqlRender`, `ROhdsiWebApi`, `Achilles` (optional, for validation)
4. **Configure connection** in `extras/codeToRun.R`:
   - `cdmSourceSchema`: `mimiciv_hosp` (the ETL expects ONE source schema by default — you may need to load both `hosp` and `icu` tables into a single combined schema, OR modify the ETL to read from two. Check the repo's docs.)
   - `cdmTargetSchema`: `mimiciv_omop`
   - `vocabDatabaseSchema`: `vocab` (your existing one — saves re-loading 5M concepts)
5. **Run the ETL scripts.** Typical sequence in OHDSI/MIMIC:
   - Concept mapping prep (loads source-to-concept maps)
   - Person, visit_occurrence, visit_detail
   - Condition, drug, measurement, procedure, observation tables
   - Era tables (condition_era, drug_era, dose_era)
6. **Logs** go to `logs/` — watch for any ERROR or FATAL.

**Validation after ETL:**
```sql
SELECT 'person' AS t, COUNT(*) FROM mimiciv_omop.person UNION ALL
SELECT 'condition_occurrence', COUNT(*) FROM mimiciv_omop.condition_occurrence UNION ALL
SELECT 'drug_exposure',        COUNT(*) FROM mimiciv_omop.drug_exposure UNION ALL
SELECT 'measurement',          COUNT(*) FROM mimiciv_omop.measurement UNION ALL
SELECT 'procedure_occurrence', COUNT(*) FROM mimiciv_omop.procedure_occurrence;
```
Expected: person ~5,000; condition_occurrence ~250K; drug_exposure ~300K; measurement ~5M.

### Phase 7 — Connect to the phenotype pipeline

In the *original* `omop-phenotype-pipeline` project, edit [config/db_config.yaml](../config/db_config.yaml):
```yaml
database:
  cdm_schema: mimiciv_omop   # was mimic_cdm
```
Then re-run `scripts/run_pipeline.R`. No other changes needed — the patient_eval module is schema-agnostic.

## Pitfalls — lessons from prior MIMIC demo work

These are issues we hit on the 100-patient demo. Same issues will recur at 5K scale; pre-empt them:

1. **`integer` vs `bigint`.** MIMIC IDs are 64-bit (e.g., `7,482,024,270,134,467,590`). Standard CDM DDL uses `integer` (32-bit). **Always use `bigint` for all `*_id` columns** when creating tables for MIMIC data. The MIT-LCP DDL gets this right; the OHDSI CommonDataModel DDL does not by default — patch if needed: `sed 's/integer NOT NULL/bigint NOT NULL/g; s/integer NULL/bigint NULL/g'`.

2. **CSV column ORDER may not match DDL order.** Even with the same column NAMES, position may differ. Always use **explicit column lists** in `\COPY`:
   ```sql
   \COPY mimiciv_hosp.diagnoses_icd (subject_id, hadm_id, seq_num, icd_code, icd_version) FROM '...'
   ```
   Read the actual CSV header line and pass it as the column list.

3. **`varchar(N)` is often too narrow** for real MIMIC values. Widen to `text` everywhere: `sed 's/varchar([0-9]*)/text/g'`.

4. **Windows command-line length limits** kill long SQL strings. Always pass large queries via `-f sqlfile.sql`, never `-c "<huge sql>"`.

5. **`\COPY` vs `COPY`.** Use `\COPY` (client-side) — it doesn't require the `postgres` OS user to have read access to your CSV files.

6. **`NULL ''`** option is required if your CSVs use empty string for NULL (most do).

7. **Use script files for multi-line Rscript code** on Windows — Git Bash with `Rscript -e '...'` can crash on multi-line `-e` arguments due to quoting issues. Write to a `.R` file and use `Rscript scripts/foo.R`.

8. **psql output on Windows includes `\r`.** When parsing query output in Python, strip with `.strip()` per line or use `splitlines()` instead of `split('\n')`.

9. **The `offset` column in some MIMIC OMOP tables** (e.g., `note_nlp`) is a SQL reserved keyword. Quote it: `"offset"`. Not in raw MIMIC tables, but watch for it in OMOP outputs.

10. **`note_nlp`, `note`, `cohort`** OMOP tables are typically empty for MIMIC and not used by phenotype work — failures here are non-blocking.

## Estimated total time

| Step | Time |
|---|---|
| Project setup | 10 min |
| Subsample patients | 5 min |
| Filter all child tables | 30-60 min (CPU-bound, depends on disk speed) |
| Create schemas + load to Postgres | 30 min |
| OHDSI ETL | 1-2 hr |
| Validation + smoke tests | 15 min |
| **Total** | **~3-4 hours** of mostly-waiting |

## Files this project should produce

```
mimic-iv-omop-etl/
├── README.md
├── CLAUDE.md                       ← copy of this blueprint, refined as work progresses
├── .gitignore
├── .env                            ← DB credentials (gitignored)
├── config.yaml
├── data/
│   ├── filtered/                   ← intermediate CSVs after subsampling
│   │   ├── sample_subjects.csv     ← the 5,000 chosen subject_ids
│   │   ├── patients.csv
│   │   ├── admissions.csv
│   │   └── ...
│   └── logs/                       ← ETL run logs
├── scripts/
│   ├── 1_extract_or_skip.sh
│   ├── 2_subsample_patients.py
│   ├── 3_filter_child_tables.py
│   ├── 4_create_schemas.sql
│   ├── 5_load_filtered_csvs.py
│   ├── 6_run_ohdsi_etl.R
│   └── 7_validate.sql
└── sql/                            ← any custom DDL or fixups
    ├── create_mimic_tables.sql     ← from MIT-LCP/mimic-code
    └── add_indexes.sql
```

## Decisions the new project lead (you / the agent) should make

1. **Subsample size.** 5,000 is the default in this blueprint. If you find phenotype counts too sparse after a test run, bump to 10,000 (doubles processing time but gives 2× the cohorts).

2. **Random seed.** Use 42 unless you have a reason. Record it in `config.yaml` so the exact patient sample is reproducible.

3. **Same DB or new DB.** Recommend same (`FHIR`) database — reuses the `vocab` schema, no duplicate 5M-row download. The new schemas (`mimiciv_hosp`, `mimiciv_icu`, `mimiciv_omop`) are independent of any existing schema.

4. **Do you need to keep the raw extracted files** after loading? Probably not — delete `data/extracted/` after Postgres load succeeds to reclaim 60+ GB.

## Reference URLs

- MIMIC-IV v3.1 dataset: https://physionet.org/content/mimiciv/3.1/
- MIMIC-IV documentation: https://mimic.mit.edu/docs/iv/
- MIT-LCP/mimic-code (load scripts): https://github.com/MIT-LCP/mimic-code
- OHDSI/MIMIC (ETL to OMOP): https://github.com/OHDSI/MIMIC
- OHDSI Common Data Model: https://github.com/OHDSI/CommonDataModel
- ATHENA vocabulary download: https://athena.ohdsi.org

## What the upstream phenotype pipeline (omop-phenotype-pipeline) expects from this output

After the ETL completes, the phenotype pipeline needs:
- A schema (call it `cdm_schema` in config) containing the standard OMOP clinical tables: `person`, `condition_occurrence`, `drug_exposure`, `measurement`, `procedure_occurrence`, `observation`, `visit_occurrence`
- All `*_concept_id` columns referencing the `vocab.concept` table
- No special indexes required beyond what the OHDSI ETL produces

Once those are in place, the only change in the upstream project is `cdm_schema: mimiciv_omop` in [config/db_config.yaml](../config/db_config.yaml). Everything else (vocabulary lookups, ancestor expansion, patient eval) works identically.
