# =============================================================================
# Evaluation — Error Analysis
# Queries the vocabulary to help classify false positives and false negatives
# by workflow phase (Phase 2 vocabulary navigation, Phase 3 expansion, etc.)
# =============================================================================

library(DBI)
library(dplyr)
library(glue)

#' Look up concept details for a set of concept_ids
#'
#' @param conn         DBI connection
#' @param concept_ids  Integer vector.
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Data frame with concept metadata.
lookup_concept_details <- function(conn, concept_ids, vocab_schema = "vocab") {
  if (length(concept_ids) == 0) return(data.frame())

  ids_str <- paste(as.integer(concept_ids), collapse = ",")
  sql <- glue("
    SELECT concept_id, concept_name, domain_id, vocabulary_id,
           standard_concept, concept_code, invalid_reason
    FROM {vocab_schema}.concept
    WHERE concept_id IN ({ids_str})
  ")
  DBI::dbGetQuery(conn, sql)
}


#' For each false negative, find its direct parents in the hierarchy.
#' If a parent was in the predicted set, the FN is a descendant gap (Phase 3).
#' If no parent was predicted, the FN is a missing anchor (Phase 2).
#'
#' @param conn          DBI connection
#' @param fn_ids        Integer vector of false negative concept_ids.
#' @param predicted_ids Integer vector of predicted concept_ids.
#' @param vocab_schema  Character. Vocabulary schema name.
#' @return Data frame classifying each FN by likely error type.
classify_false_negatives <- function(conn, fn_ids, predicted_ids,
                                      vocab_schema = "vocab") {
  if (length(fn_ids) == 0) return(data.frame())

  fn_details <- lookup_concept_details(conn, fn_ids, vocab_schema)

  results <- lapply(fn_ids, function(fn_id) {

    # Get direct parents (min_levels_of_separation = 1)
    parent_sql <- glue("
      SELECT ca.ancestor_concept_id AS parent_id,
             c.concept_name         AS parent_name
      FROM {vocab_schema}.concept_ancestor ca
      JOIN {vocab_schema}.concept c
        ON ca.ancestor_concept_id = c.concept_id
      WHERE ca.descendant_concept_id = {fn_id}
        AND ca.min_levels_of_separation = 1
    ")
    parents <- DBI::dbGetQuery(conn, parent_sql)

    parent_predicted <- if (nrow(parents) > 0) {
      any(parents$parent_id %in% predicted_ids)
    } else FALSE

    concept_row <- fn_details[fn_details$concept_id == fn_id, ]

    list(
      concept_id       = fn_id,
      concept_name     = if (nrow(concept_row) > 0) concept_row$concept_name[1] else NA,
      domain_id        = if (nrow(concept_row) > 0) concept_row$domain_id[1]    else NA,
      vocabulary_id    = if (nrow(concept_row) > 0) concept_row$vocabulary_id[1] else NA,
      n_parents        = nrow(parents),
      parent_predicted = parent_predicted,
      likely_error     = if (parent_predicted) {
        "Phase3_descendant_gap"   # ancestor was predicted but include_descendants missed this
      } else if (nrow(parents) == 0) {
        "Phase3_leaf_concept"     # no parent — very specific leaf, may need explicit inclusion
      } else {
        "Phase2_missing_anchor"   # parent not predicted — LLM missed the clinical concept
      }
    )
  })

  dplyr::bind_rows(lapply(results, as.data.frame))
}


#' Print a readable error analysis summary
#'
#' @param eval_result Named list from run_evaluation()
#' @param conn        DBI connection
#' @param vocab_schema Character. Vocabulary schema name.
diagnose_errors <- function(eval_result, conn, vocab_schema = "vocab") {

  cat("\n--- Error Analysis:", eval_result$phenotype,
      "|", eval_result$model, "---\n")

  if (length(eval_result$false_negative_ids) > 0) {
    cat("\nFalse Negatives (missed gold concepts):\n")
    fn_class <- classify_false_negatives(
      conn,
      eval_result$false_negative_ids,
      eval_result$predicted_ids %||% integer(0),
      vocab_schema
    )
    print(fn_class[, c("concept_name","domain_id","vocabulary_id","likely_error")])
  }

  if (length(eval_result$false_positive_ids) > 0) {
    cat("\nFalse Positives (predicted but not in gold):\n")
    fp_details <- lookup_concept_details(conn, eval_result$false_positive_ids,
                                          vocab_schema)
    if (nrow(fp_details) > 0) {
      print(fp_details[, c("concept_id","concept_name","domain_id","vocabulary_id")])
    }
  }
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
