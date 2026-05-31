# =============================================================================
# Phase 5 — Patient-Level Evaluation
# Compares the patient cohort identified by the predicted concept set against
# the patient cohort identified by the gold-standard concept set.
#
# This is the *clinically meaningful* metric: how many real patients would be
# correctly flagged if you ran the predicted concept set against actual EHR data.
# Concept-set F1 is an upper bound on rigor; patient F1 reflects clinical reality.
# =============================================================================

library(DBI)
library(glue)
library(jsonlite)

#' Distinct patient IDs whose records reference any of the given concept_ids
#'
#' Searches the 5 main CDM clinical tables: condition_occurrence, drug_exposure,
#' measurement, procedure_occurrence, observation. Uses each table's standard
#' concept_id column (not source).
#'
#' @param conn        DBI connection
#' @param concept_ids Integer vector of OMOP standard concept_ids
#' @param cdm_schema  Character. Schema holding the patient-level CDM tables.
#' @return Integer vector of distinct person_ids (empty if no matches).
patients_for_concepts <- function(conn, concept_ids, cdm_schema = "cdm") {
  concept_ids <- unique(as.integer(concept_ids))
  concept_ids <- concept_ids[!is.na(concept_ids)]
  if (length(concept_ids) == 0) return(integer(0))

  ids_csv <- paste(concept_ids, collapse = ",")
  sql <- glue("
    SELECT DISTINCT person_id FROM (
      SELECT person_id FROM {cdm_schema}.condition_occurrence
        WHERE condition_concept_id = ANY(ARRAY[{ids_csv}]::bigint[])
      UNION
      SELECT person_id FROM {cdm_schema}.drug_exposure
        WHERE drug_concept_id = ANY(ARRAY[{ids_csv}]::bigint[])
      UNION
      SELECT person_id FROM {cdm_schema}.measurement
        WHERE measurement_concept_id = ANY(ARRAY[{ids_csv}]::bigint[])
      UNION
      SELECT person_id FROM {cdm_schema}.procedure_occurrence
        WHERE procedure_concept_id = ANY(ARRAY[{ids_csv}]::bigint[])
      UNION
      SELECT person_id FROM {cdm_schema}.observation
        WHERE observation_concept_id = ANY(ARRAY[{ids_csv}]::bigint[])
    ) p
  ")
  DBI::dbGetQuery(conn, sql)$person_id
}


#' Expand a set of seed concept_ids to seeds + all standard descendants
#'
#' The OHDSI gold standards store SEEDS only (with `include_descendants: true`
#' as metadata). For a fair patient-cohort comparison, the gold patient query
#' must use the seeds plus their concept_ancestor descendants — the same
#' expansion the prediction goes through in Phase 3.
#'
#' @param conn         DBI connection
#' @param seed_ids     Integer vector of seed concept_ids
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Integer vector of expanded standard concept_ids (includes seeds).
expand_seeds_to_standard <- function(conn, seed_ids, vocab_schema = "vocab") {
  seed_ids <- unique(as.integer(seed_ids))
  seed_ids <- seed_ids[!is.na(seed_ids)]
  if (length(seed_ids) == 0) return(integer(0))

  ids_csv <- paste(seed_ids, collapse = ",")
  sql <- glue("
    WITH seeds AS (SELECT unnest(ARRAY[{ids_csv}]::bigint[]) AS cid),
    expanded AS (
      SELECT cid FROM seeds
      UNION
      SELECT descendant_concept_id FROM {vocab_schema}.concept_ancestor
        WHERE ancestor_concept_id IN (SELECT cid FROM seeds)
    )
    SELECT e.cid AS concept_id
    FROM expanded e
    JOIN {vocab_schema}.concept c ON c.concept_id = e.cid
    WHERE c.standard_concept = 'S' AND c.invalid_reason IS NULL
  ")
  DBI::dbGetQuery(conn, sql)$concept_id
}


#' Per-patient classification (TP / FP / FN) for one phenotype × predicted set
#'
#' Returns a long data frame with one row per patient who was matched by either
#' the predicted concept set or the (expanded) gold concept set.
#'
#' @param conn          DBI connection
#' @param predicted_ids Integer vector — already-expanded predicted concept_ids
#' @param gold_seed_ids Integer vector — seed concept_ids from the gold JSON
#' @param vocab_schema  Character. Vocabulary schema name.
#' @param cdm_schema    Character. Patient-data schema name.
#' @return Data frame with columns: person_id, in_predicted, in_gold, classification
classify_patients <- function(conn, predicted_ids, gold_seed_ids,
                              vocab_schema = "vocab", cdm_schema = "cdm") {
  gold_expanded <- expand_seeds_to_standard(conn, gold_seed_ids, vocab_schema)
  pred_pts <- patients_for_concepts(conn, predicted_ids, cdm_schema)
  gold_pts <- patients_for_concepts(conn, gold_expanded, cdm_schema)
  all_pts  <- sort(unique(c(pred_pts, gold_pts)))

  in_pred <- all_pts %in% pred_pts
  in_gold <- all_pts %in% gold_pts

  data.frame(
    person_id      = all_pts,
    in_predicted   = in_pred,
    in_gold        = in_gold,
    classification = ifelse(in_pred &  in_gold, "TP",
                     ifelse(in_pred & !in_gold, "FP", "FN")),
    stringsAsFactors = FALSE
  )
}


#' Patient-level precision / recall / F1 for one phenotype × model × trial
#'
#' @param conn          DBI connection
#' @param predicted_ids Integer vector — the pipeline's expanded predicted concept_ids.
#'                      (Already includes descendants from Phase 3.)
#' @param gold_seed_ids Integer vector — seed concept_ids from the gold JSON.
#'                      Expanded internally to match how the gold cohort would
#'                      actually be defined in ATLAS.
#' @param vocab_schema  Character. Vocabulary schema name.
#' @param cdm_schema    Character. Patient-data schema name.
#' @return Named list with patient counts, metrics, AND the per-patient
#'         classification data frame (as patient_df) for downstream inspection.
evaluate_patients <- function(conn, predicted_ids, gold_seed_ids,
                              vocab_schema = "vocab", cdm_schema = "cdm") {

  df <- classify_patients(conn, predicted_ids, gold_seed_ids, vocab_schema, cdm_schema)

  tp <- sum(df$classification == "TP")
  fp <- sum(df$classification == "FP")
  fn <- sum(df$classification == "FN")

  prec <- if ((tp + fp) > 0) tp / (tp + fp) else 0
  rec  <- if ((tp + fn) > 0) tp / (tp + fn) else 0
  f1   <- if ((prec + rec) > 0) 2 * prec * rec / (prec + rec) else 0

  message("  Patient-level: predicted=", tp + fp,
          " | gold=", tp + fn,
          " | TP=", tp, " FP=", fp, " FN=", fn,
          " | P=", round(prec, 3),
          " R=", round(rec, 3),
          " F1=", round(f1, 3))

  list(
    n_pred_patients   = tp + fp,
    n_gold_patients   = tp + fn,
    patient_tp        = tp,
    patient_fp        = fp,
    patient_fn        = fn,
    patient_precision = prec,
    patient_recall    = rec,
    patient_f1        = f1,
    patient_df        = df
  )
}
