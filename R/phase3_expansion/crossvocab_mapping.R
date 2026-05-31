# =============================================================================
# Phase 3 — Cross-Vocabulary Mapping
# For each standard concept, finds source codes that map to it via
# CONCEPT_RELATIONSHIP (relationship_id = 'Maps to').
# Used to verify ETL coverage — i.e. which ICD-10 codes bring patients
# into this phenotype through the standard concept.
# =============================================================================

library(DBI)
library(dplyr)
library(glue)

#' Get source code mappings for a set of standard concept_ids
#'
#' @param conn               DBI connection
#' @param concept_ids        Integer vector of standard concept_ids.
#' @param target_vocabularies Character vector of source vocabularies to retrieve.
#' @param vocab_schema       Character. Vocabulary schema name.
#' @return Data frame of source code ↔ standard concept mappings.
get_source_code_mappings <- function(conn,
                                      concept_ids,
                                      target_vocabularies = c("ICD10CM","ICD9CM",
                                                              "RxNorm","LOINC","CPT4"),
                                      vocab_schema = "vocab") {

  if (length(concept_ids) == 0) return(data.frame())

  # Build a parameterised IN list
  ids_str    <- paste(as.integer(concept_ids), collapse = ",")
  vocabs_str <- paste0("'", target_vocabularies, "'", collapse = ",")

  sql <- glue("
    SELECT c_src.concept_code    AS source_code,
           c_src.concept_name    AS source_name,
           c_src.vocabulary_id   AS source_vocab,
           c_std.concept_id      AS standard_concept_id,
           c_std.concept_name    AS standard_name,
           c_std.domain_id       AS domain_id
    FROM {vocab_schema}.concept_relationship cr
    JOIN {vocab_schema}.concept c_src
      ON cr.concept_id_1 = c_src.concept_id
    JOIN {vocab_schema}.concept c_std
      ON cr.concept_id_2 = c_std.concept_id
    WHERE cr.relationship_id = 'Maps to'
      AND cr.invalid_reason IS NULL
      AND c_std.concept_id IN ({ids_str})
      AND c_src.vocabulary_id IN ({vocabs_str})
    ORDER BY c_src.vocabulary_id, c_src.concept_code
  ")

  result <- tryCatch(
    DBI::dbGetQuery(conn, sql),
    error = function(e) {
      warning("Cross-vocabulary mapping query failed: ", e$message)
      data.frame()
    }
  )

  if (nrow(result) > 0) {
    message("  Cross-vocabulary mappings found: ", nrow(result),
            " across ", length(unique(result$source_vocab)), " vocabularies")
    vocab_summary <- result |> count(source_vocab, sort = TRUE)
    for (i in seq_len(nrow(vocab_summary))) {
      message("    ", vocab_summary$source_vocab[i], ": ",
              vocab_summary$n[i], " codes")
    }
  } else {
    message("  No cross-vocabulary mappings found for provided concept_ids.")
  }

  result
}


#' Find the standard concept(s) that an ICD-10 code maps TO
#' (useful for gap analysis — verifying ETL is mapping source codes correctly)
#'
#' @param conn         DBI connection
#' @param icd10_code   Character. ICD-10-CM code, e.g. "E11.9"
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Data frame with standard concept(s) for that ICD-10 code.
icd10_to_standard <- function(conn, icd10_code, vocab_schema = "vocab") {

  sql <- glue("
    SELECT c_src.concept_code   AS icd10_code,
           c_src.concept_name   AS icd10_name,
           c_std.concept_id     AS standard_concept_id,
           c_std.concept_name   AS standard_name,
           c_std.vocabulary_id  AS standard_vocab,
           c_std.domain_id      AS domain_id
    FROM {vocab_schema}.concept c_src
    JOIN {vocab_schema}.concept_relationship cr
      ON c_src.concept_id = cr.concept_id_1
    JOIN {vocab_schema}.concept c_std
      ON cr.concept_id_2 = c_std.concept_id
    WHERE c_src.vocabulary_id = 'ICD10CM'
      AND c_src.concept_code  = $1
      AND cr.relationship_id  = 'Maps to'
      AND cr.invalid_reason   IS NULL
      AND c_std.standard_concept = 'S'
  ")

  DBI::dbGetQuery(conn, sql, params = list(icd10_code))
}
