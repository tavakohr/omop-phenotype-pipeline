# =============================================================================
# Trivial-seed baseline — answers reviewer concern that high patient F1 may be
# an ancestor-expansion saturation artifact, not LLM skill.
#
# For each phenotype, take 1-2 obvious anchor concept names, expand via
# concept_ancestor, apply the same Measurement-domain lab filter as the LLM
# pipeline, then run Phase 5 patient-level evaluation. If this trivial baseline
# already scores ~0.9 patient F1, the LLM's marginal contribution is small.
#
# Writes: data/results/trivial_baseline_summary.csv
# =============================================================================

library(dotenv)
library(yaml)
library(DBI)
library(dplyr)
library(readr)
library(glue)
library(jsonlite)

if (file.exists(".env")) dotenv::load_dot_env(".env")

source("R/phase2_lookup/db_connector.R")
source("R/evaluation/patient_eval.R")

config       <- load_config("config/db_config.yaml")
vocab_schema <- config$database$vocab_schema
cdm_schema   <- config$database$cdm_schema

# Each entry: list of (domain, name-alternatives) pairs. Domain filter prevents
# wrong-vocabulary collisions (e.g. "Atrial fibrillation" exists as both a SNOMED
# Condition and a LOINC Meas Value). Alternatives are tried in order until one
# resolves; first match wins.
TRIVIAL_SEEDS <- list(
  t2dm = list(
    list("Condition", c("Type 2 diabetes mellitus"))
  ),
  cardiac_valve_af = list(
    list("Condition", c("Atrial fibrillation")),
    list("Procedure", c("Heart valve replacement", "Replacement of heart valve",
                        "Operation on heart valve"))
  ),
  acute_liver_injury = list(
    list("Condition", c("Liver disease", "Disease of liver",
                        "Disorder of liver", "Hepatic disorder",
                        "Acute liver injury"))
  ),
  drug_pancreatitis = list(
    list("Condition", c("Acute pancreatitis"))
  ),
  trd = list(
    list("Condition", c("Major depressive disorder", "Major depression"))
  )
)


# Resolve one seed-spec (domain + list of name alternatives) -> 1 row. Tries each
# name in order, filtering by expected domain. Returns first match.
lookup_seed_id <- function(conn, expected_domain, names, vocab_schema) {
  for (nm in names) {
    sql <- glue("
      SELECT concept_id, concept_name, domain_id, vocabulary_id
      FROM {vocab_schema}.concept
      WHERE LOWER(concept_name) = LOWER($1)
        AND domain_id = $2
        AND standard_concept = 'S'
        AND invalid_reason IS NULL
      LIMIT 1
    ")
    res <- DBI::dbGetQuery(conn, sql, params = list(nm, expected_domain))
    if (nrow(res) > 0) {
      cat("  resolved '", nm, "' -> ", res$concept_id, " (", res$concept_name,
          ", ", res$vocabulary_id, ")\n", sep = "")
      return(res)
    }
  }
  stop("None of these trivial-seed names resolved in domain '", expected_domain,
       "': ", paste(names, collapse = ", "))
}


get_domains <- function(conn, ids, vocab_schema) {
  if (length(ids) == 0) return(data.frame(concept_id = integer(0), domain_id = character(0)))
  ids_csv <- paste(as.integer(ids), collapse = ",")
  sql <- glue("
    SELECT concept_id, domain_id
    FROM {vocab_schema}.concept
    WHERE concept_id = ANY(ARRAY[{ids_csv}]::bigint[])
  ")
  DBI::dbGetQuery(conn, sql)
}


conn <- connect_db(config)
on.exit(DBI::dbDisconnect(conn), add = TRUE)

results <- list()

for (cfg_name in names(TRIVIAL_SEEDS)) {
  specs <- TRIVIAL_SEEDS[[cfg_name]]
  cat("\n", strrep("=", 65), "\n", sep = "")
  cat("Phenotype: ", cfg_name, "\n", sep = "")
  cat(strrep("=", 65), "\n", sep = "")

  # Resolve each seed-spec; collect rows
  seed_rows <- do.call(rbind, lapply(specs, function(sp) {
    lookup_seed_id(conn, sp[[1]], sp[[2]], vocab_schema)
  }))
  seed_ids <- as.integer(seed_rows$concept_id)
  seed_label <- paste(seed_rows$concept_name, collapse = " + ")

  # Expand via concept_ancestor (same as LLM pipeline Phase 3 logic)
  expanded_ids <- expand_seeds_to_standard(conn, seed_ids, vocab_schema)
  cat("Expanded to ", length(expanded_ids), " standard concept_ids\n", sep = "")

  # Apply Measurement-domain lab filter (same as LLM pipeline Phase 5)
  ph_cfg <- Filter(function(p) p$key == cfg_name, config$phenotypes)[[1]]
  if (isTRUE(ph_cfg$exclude_labs_in_patient_query)) {
    dom <- get_domains(conn, expanded_ids, vocab_schema)
    n_before <- length(expanded_ids)
    expanded_ids <- dom$concept_id[dom$domain_id != "Measurement"]
    cat("Lab filter: dropped ", n_before - length(expanded_ids),
        " Measurement-domain concepts\n", sep = "")
  }

  # Patient-level eval vs gold-derived cohort (same comparator as LLM pipeline)
  gold_seed_ids <- jsonlite::fromJSON(ph_cfg$gold)$gold_concept_ids
  pe <- evaluate_patients(conn, expanded_ids, gold_seed_ids,
                          vocab_schema = vocab_schema,
                          cdm_schema   = cdm_schema)

  results[[cfg_name]] <- data.frame(
    phenotype          = cfg_name,
    trivial_seed_names = seed_label,
    n_seed_ids         = length(seed_ids),
    n_expanded_ids     = length(expanded_ids),
    n_pred_patients    = pe$n_pred_patients,
    n_gold_patients    = pe$n_gold_patients,
    patient_tp         = pe$patient_tp,
    patient_fp         = pe$patient_fp,
    patient_fn         = pe$patient_fn,
    patient_precision  = pe$patient_precision,
    patient_recall     = pe$patient_recall,
    patient_f1         = pe$patient_f1,
    stringsAsFactors   = FALSE
  )
}

out <- dplyr::bind_rows(results)
out_path <- "data/results/trivial_baseline_summary.csv"
dir.create("data/results", showWarnings = FALSE, recursive = TRUE)
readr::write_csv(out, out_path)

cat("\n", strrep("=", 65), "\n", sep = "")
cat("Trivial-seed baseline written to: ", out_path, "\n", sep = "")
cat(strrep("=", 65), "\n\n", sep = "")
print(out[, c("phenotype", "n_expanded_ids", "n_pred_patients", "n_gold_patients",
              "patient_precision", "patient_recall", "patient_f1")])
