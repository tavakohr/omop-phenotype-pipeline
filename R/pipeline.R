# =============================================================================
# MAIN ORCHESTRATOR
# Runs the full LLM + SQL phenotype pipeline for one phenotype × one model.
# Call run_phenotype() directly, or use scripts/run_pipeline.R for batch runs.
# =============================================================================

# Source all modules
source("R/phase1_llm/prompt_builder.R")
source("R/phase1_llm/llm_client.R")
source("R/phase1_llm/response_parser.R")
source("R/phase2_lookup/db_connector.R")
source("R/phase2_lookup/concept_lookup.R")
source("R/phase2_lookup/lookup_report.R")
source("R/phase3_expansion/ancestor_expansion.R")
source("R/phase3_expansion/crossvocab_mapping.R")
source("R/evaluation/scorer.R")
source("R/evaluation/error_analysis.R")
source("R/evaluation/patient_eval.R")

library(dotenv)
library(yaml)
library(dplyr)
library(readr)


#' Run the full pipeline for one phenotype × one model × one trial
#'
#' @param phenotype_key Character. Key matching an entry in config phenotypes.
#' @param model_cfg     Named list with provider, model, temperature, etc.
#' @param config        Named list from load_config().
#' @param trial         Integer. Trial number (for repeated runs).
#' @return Named list with all pipeline results.
run_phenotype <- function(phenotype_key, model_cfg, config, trial = 1) {

  # Find phenotype config
  ph_cfg <- Filter(function(p) p$key == phenotype_key, config$phenotypes)
  if (length(ph_cfg) == 0) stop("Phenotype key '", phenotype_key, "' not found in config.")
  ph_cfg <- ph_cfg[[1]]

  vocab_schema <- config$database$vocab_schema

  cat("\n", strrep("#", 65), "\n")
  cat("Phenotype:", phenotype_key,
      " | Model:", model_cfg$label,
      " | Trial:", trial, "\n")
  cat(strrep("#", 65), "\n")

  # ── Phase 1: LLM generates concept names ────────────────────────────────────
  cat("\n[Phase 1] LLM concept name generation...\n")

  prompt    <- build_prompt(ph_cfg$brief, max_concepts = config$pipeline$max_concepts_per_phenotype)
  raw_text  <- call_llm(prompt,
                         provider    = model_cfg$provider,
                         model       = model_cfg$model,
                         temperature = model_cfg$temperature,
                         max_tokens  = model_cfg$max_output_tokens)
  concepts_df <- parse_llm_response(raw_text)

  # ── Phase 2: SQL lookup ──────────────────────────────────────────────────────
  cat("\n[Phase 2] Vocabulary table lookup...\n")

  conn      <- connect_db(config)
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  lookup_df <- lookup_all_concepts(conn, concepts_df, vocab_schema = vocab_schema)
  report    <- generate_lookup_report(lookup_df, phenotype = phenotype_key)

  # ── Phase 3: Expansion ───────────────────────────────────────────────────────
  cat("\n[Phase 3] Concept set expansion...\n")

  expanded_df <- expand_concept_set(
    conn, lookup_df,
    max_levels   = config$pipeline$expansion$max_descendant_levels,
    vocab_schema = vocab_schema
  )

  # Cross-vocabulary mapping (informational)
  if (isTRUE(config$pipeline$expansion$include_cross_vocab)) {
    inclusion_ids <- expanded_df |>
      filter(!is_excluded, !is.na(concept_id)) |>
      pull(concept_id) |>
      as.integer()

    crossvocab_df <- get_source_code_mappings(
      conn, inclusion_ids,
      target_vocabularies = config$pipeline$expansion$target_vocabularies,
      vocab_schema        = vocab_schema
    )
  }

  # ── Phase 4: Evaluation ──────────────────────────────────────────────────────
  cat("\n[Phase 4] Evaluation against gold standard...\n")

  eval_result <- run_evaluation(
    conn, expanded_df,
    gold_path    = ph_cfg$gold,
    phenotype    = phenotype_key,
    model_label  = model_cfg$label,
    trial        = trial,
    vocab_schema = vocab_schema
  )

  # ── Phase 5: Patient-level evaluation ────────────────────────────────────────
  cat("\n[Phase 5] Patient-level evaluation...\n")

  pred_df <- expanded_df |>
    filter(!is_excluded, !is.na(concept_id))

  # Phenotype-aware lab filtering: for condition-/procedure-coded phenotypes
  # (T2DM, cardiac surgery, depression), lab CONCEPT hits flood the cohort
  # with every patient who had that lab drawn (most ICU patients).
  # See investigation in ddl_tmp/investigate_extremes.py.
  if (isTRUE(ph_cfg$exclude_labs_in_patient_query)) {
    n_before <- nrow(pred_df)
    pred_df <- pred_df |> filter(domain_id != "Measurement")
    cat("  exclude_labs_in_patient_query=true: dropped ",
        n_before - nrow(pred_df), " Measurement-domain concepts from patient query\n", sep = "")
  }

  pred_ids <- as.integer(pred_df$concept_id)
  gold_seed_ids <- jsonlite::fromJSON(ph_cfg$gold)$gold_concept_ids

  patient_eval <- tryCatch(
    evaluate_patients(conn, pred_ids, gold_seed_ids,
                      vocab_schema = vocab_schema,
                      cdm_schema   = config$database$cdm_schema),
    error = function(e) {
      warning("Patient eval failed: ", e$message)
      list(n_pred_patients = NA_integer_, n_gold_patients = NA_integer_,
           patient_tp = NA_integer_, patient_fp = NA_integer_, patient_fn = NA_integer_,
           patient_precision = NA_real_, patient_recall = NA_real_, patient_f1 = NA_real_)
    }
  )

  # Persist the expanded set so future analyses can re-score without re-calling the LLM
  dir.create("data/results/expanded", showWarnings = FALSE, recursive = TRUE)
  exp_path <- file.path("data/results/expanded",
                        paste0(phenotype_key, "_", model_cfg$label, "_trial", trial, ".csv"))
  readr::write_csv(expanded_df, exp_path)

  # Persist per-patient classification (TP/FP/FN) for downstream clinical inspection
  if (!is.null(patient_eval$patient_df) && nrow(patient_eval$patient_df) > 0) {
    dir.create("data/results/patients", showWarnings = FALSE, recursive = TRUE)
    pat_path <- file.path("data/results/patients",
                          paste0(phenotype_key, "_", model_cfg$label, "_trial", trial, ".csv"))
    readr::write_csv(patient_eval$patient_df, pat_path)
  }

  # Compile summary row
  summary_row <- data.frame(
    phenotype       = phenotype_key,
    model           = model_cfg$label,
    trial           = trial,
    llm_concepts    = nrow(concepts_df),
    resolved        = report$resolved,
    unresolved      = report$unresolved,
    resolution_rate = report$resolution_rate,
    expanded_total  = nrow(expanded_df[!expanded_df$is_excluded, ]),
    n_gold          = eval_result$n_gold,
    precision       = eval_result$precision,
    recall          = eval_result$recall,
    f1              = eval_result$f1,
    jaccard         = eval_result$jaccard,
    precision_aa    = eval_result$precision_aa,
    recall_aa       = eval_result$recall_aa,
    f1_aa           = eval_result$f1_aa,
    tp              = eval_result$tp,
    fp              = eval_result$fp,
    fn              = eval_result$fn,
    n_pred_patients   = patient_eval$n_pred_patients,
    n_gold_patients   = patient_eval$n_gold_patients,
    patient_tp        = patient_eval$patient_tp,
    patient_fp        = patient_eval$patient_fp,
    patient_fn        = patient_eval$patient_fn,
    patient_precision = patient_eval$patient_precision,
    patient_recall    = patient_eval$patient_recall,
    patient_f1        = patient_eval$patient_f1,
    stringsAsFactors = FALSE
  )

  list(
    summary    = summary_row,
    concepts   = concepts_df,
    lookup     = lookup_df,
    expanded   = expanded_df,
    eval       = eval_result
  )
}
