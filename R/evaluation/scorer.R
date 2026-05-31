# =============================================================================
# Evaluation — Scorer
# Computes precision, recall, F1, Jaccard against the gold standard.
# Two modes: exact concept_id match and ancestor-aware match.
# =============================================================================

library(DBI)
library(dplyr)
library(jsonlite)
library(glue)

#' Load a gold standard JSON file
#'
#' @param gold_path Path to gold standard JSON file.
#' @return Named list with gold_concept_ids, excluded_concept_ids, etc.
load_gold_standard <- function(gold_path) {
  if (!file.exists(gold_path)) {
    stop("Gold standard file not found: ", gold_path)
  }
  jsonlite::fromJSON(gold_path)
}


#' Compute exact set-based metrics
#'
#' @param predicted_ids Integer vector of predicted concept_ids (inclusion only).
#' @param gold_ids      Integer vector of gold standard concept_ids.
#' @return Named numeric vector: precision, recall, f1, jaccard, tp, fp, fn.
exact_score <- function(predicted_ids, gold_ids) {
  predicted_ids <- unique(as.integer(predicted_ids[!is.na(predicted_ids)]))
  gold_ids      <- unique(as.integer(gold_ids))

  tp <- length(intersect(predicted_ids, gold_ids))
  fp <- length(setdiff(predicted_ids,  gold_ids))
  fn <- length(setdiff(gold_ids,       predicted_ids))

  precision <- if (length(predicted_ids) > 0) tp / length(predicted_ids) else 0
  recall    <- if (length(gold_ids)      > 0) tp / length(gold_ids)      else 0
  f1        <- if ((precision + recall)  > 0) 2 * precision * recall / (precision + recall) else 0
  union_n   <- length(union(predicted_ids, gold_ids))
  jaccard   <- if (union_n > 0) tp / union_n else 0

  c(precision = precision, recall = recall, f1 = f1, jaccard = jaccard,
    tp = tp, fp = fp, fn = fn,
    n_predicted = length(predicted_ids), n_gold = length(gold_ids))
}


#' Compute ancestor-aware metrics
#' Credits a prediction if it IS a gold concept OR a descendant of one.
#'
#' @param conn          DBI connection
#' @param predicted_ids Integer vector of predicted concept_ids.
#' @param gold_ids      Integer vector of gold standard concept_ids.
#' @param vocab_schema  Character. Vocabulary schema name.
#' @return Named numeric vector: precision_aa, recall_aa, f1_aa.
ancestor_aware_score <- function(conn, predicted_ids, gold_ids,
                                  vocab_schema = "vocab") {

  predicted_ids <- unique(as.integer(predicted_ids[!is.na(predicted_ids)]))
  gold_ids      <- unique(as.integer(gold_ids))

  if (length(predicted_ids) == 0 || length(gold_ids) == 0) {
    return(c(precision_aa = 0, recall_aa = 0, f1_aa = 0))
  }

  # Fetch all descendants of all gold concepts in one query
  gold_str <- paste(gold_ids, collapse = ",")
  sql <- glue("
    SELECT DISTINCT descendant_concept_id
    FROM {vocab_schema}.concept_ancestor
    WHERE ancestor_concept_id IN ({gold_str})
  ")
  gold_descendants <- DBI::dbGetQuery(conn, sql)$descendant_concept_id
  gold_universe    <- union(gold_ids, gold_descendants)

  # TP_pred: predictions covered by the gold hierarchy
  tp_pred <- intersect(predicted_ids, gold_universe)

  # TP_gold: gold concepts hit by any prediction
  tp_gold <- intersect(gold_ids, gold_universe[gold_universe %in% predicted_ids])
  # Simpler: which gold concepts have at least one prediction in their subtree?
  tp_gold_count <- sum(sapply(gold_ids, function(g) {
    subtree_g <- DBI::dbGetQuery(conn, glue(
      "SELECT descendant_concept_id FROM {vocab_schema}.concept_ancestor
       WHERE ancestor_concept_id = {g}"
    ))$descendant_concept_id
    subtree_g <- union(g, subtree_g)
    any(predicted_ids %in% subtree_g)
  }))

  precision_aa <- length(tp_pred) / length(predicted_ids)
  recall_aa    <- tp_gold_count   / length(gold_ids)
  f1_aa        <- if ((precision_aa + recall_aa) > 0) {
    2 * precision_aa * recall_aa / (precision_aa + recall_aa)
  } else 0

  c(precision_aa = precision_aa, recall_aa = recall_aa, f1_aa = f1_aa,
    tp_pred_count = length(tp_pred), tp_gold_count = tp_gold_count)
}


#' Full evaluation for one phenotype × model trial
#'
#' @param conn         DBI connection
#' @param expanded_df  Data frame from expand_concept_set()
#' @param gold_path    Path to gold standard JSON
#' @param phenotype    Character. Phenotype label.
#' @param model_label  Character. Model label (e.g. "claude_opus_4_6")
#' @param trial        Integer. Trial number.
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Named list of all evaluation results.
run_evaluation <- function(conn, expanded_df, gold_path,
                            phenotype, model_label, trial = 1,
                            vocab_schema = "vocab") {

  gs        <- load_gold_standard(gold_path)
  gold_ids  <- as.integer(gs$gold_concept_ids)

  # Inclusion concepts only (is_excluded == FALSE)
  predicted_ids <- expanded_df |>
    filter(!is_excluded, !is.na(concept_id)) |>
    pull(concept_id) |>
    as.integer() |>
    unique()

  exact <- exact_score(predicted_ids, gold_ids)
  aa    <- ancestor_aware_score(conn, predicted_ids, gold_ids, vocab_schema)

  fp_ids <- setdiff(predicted_ids, gold_ids)
  fn_ids <- setdiff(gold_ids,      predicted_ids)

  cat("\n", strrep("=", 60), "\n")
  cat("Phenotype:", phenotype, " | Model:", model_label, " | Trial:", trial, "\n")
  cat("  Predicted:", length(predicted_ids), " | Gold:", length(gold_ids), "\n")
  cat(sprintf("  Exact    — P: %.3f  R: %.3f  F1: %.3f  J: %.3f\n",
              exact["precision"], exact["recall"], exact["f1"], exact["jaccard"]))
  cat(sprintf("  Ancestor — P: %.3f  R: %.3f  F1: %.3f\n",
              aa["precision_aa"], aa["recall_aa"], aa["f1_aa"]))
  cat("  FP:", exact["fp"], " | FN:", exact["fn"], "\n")

  list(
    phenotype          = phenotype,
    model              = model_label,
    trial              = trial,
    n_predicted        = length(predicted_ids),
    n_gold             = length(gold_ids),
    precision          = unname(exact["precision"]),
    recall             = unname(exact["recall"]),
    f1                 = unname(exact["f1"]),
    jaccard            = unname(exact["jaccard"]),
    tp                 = unname(exact["tp"]),
    fp                 = unname(exact["fp"]),
    fn                 = unname(exact["fn"]),
    precision_aa       = unname(aa["precision_aa"]),
    recall_aa          = unname(aa["recall_aa"]),
    f1_aa              = unname(aa["f1_aa"]),
    false_positive_ids = fp_ids,
    false_negative_ids = fn_ids
  )
}
