# =============================================================================
# Phase 2 — Concept Lookup (5-Tier SQL Cascade)
# Resolves LLM-generated concept names to standard OMOP concept_ids
# by querying the real vocabulary tables in PostgreSQL.
#
# Tier 1: Exact match on concept_name  (standard concepts, domain-filtered)
# Tier 2: Exact match on synonym       (standard concepts, domain-filtered)
# Tier 3: Exact match on concept_name  (standard concepts, any domain)
# Tier 4: Exact match on synonym       (standard concepts, any domain)
# Tier 5: Fuzzy LIKE on concept_name   (standard concepts, domain-filtered)
# =============================================================================

library(DBI)
library(dplyr)
library(glue)

#' Resolve a single concept name to a standard OMOP concept_id
#'
#' @param conn         DBI connection
#' @param name         Character. Concept name from LLM output.
#' @param domain       Character. Expected OMOP domain (e.g. "Condition", "Drug").
#' @param vocab_schema Character. Vocabulary schema name.
#' @return A one-row data frame with concept_id and metadata, or unresolved row.
lookup_concept <- function(conn, name, domain, vocab_schema = "vocab") {

  tiers <- list(

    list(
      tier = "1_exact_name_std",
      sql  = glue("
        SELECT concept_id, concept_name, domain_id, vocabulary_id,
               standard_concept, concept_code
        FROM {vocab_schema}.concept
        WHERE LOWER(concept_name) = LOWER($1)
          AND standard_concept = 'S'
          AND invalid_reason IS NULL
          AND domain_id = $2
        LIMIT 1
      "),
      params = list(name, domain)
    ),

    list(
      tier = "2_synonym_std",
      sql  = glue("
        SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
               c.standard_concept, c.concept_code
        FROM {vocab_schema}.concept c
        JOIN {vocab_schema}.concept_synonym cs
          ON c.concept_id = cs.concept_id
        WHERE LOWER(cs.concept_synonym_name) = LOWER($1)
          AND c.standard_concept = 'S'
          AND c.invalid_reason IS NULL
          AND c.domain_id = $2
        LIMIT 1
      "),
      params = list(name, domain)
    ),

    list(
      tier = "3_exact_name_any_domain",
      sql  = glue("
        SELECT concept_id, concept_name, domain_id, vocabulary_id,
               standard_concept, concept_code
        FROM {vocab_schema}.concept
        WHERE LOWER(concept_name) = LOWER($1)
          AND standard_concept = 'S'
          AND invalid_reason IS NULL
        LIMIT 1
      "),
      params = list(name)
    ),

    list(
      tier = "4_synonym_any_domain",
      sql  = glue("
        SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
               c.standard_concept, c.concept_code
        FROM {vocab_schema}.concept c
        JOIN {vocab_schema}.concept_synonym cs
          ON c.concept_id = cs.concept_id
        WHERE LOWER(cs.concept_synonym_name) = LOWER($1)
          AND c.standard_concept = 'S'
          AND c.invalid_reason IS NULL
        LIMIT 1
      "),
      params = list(name)
    ),

    list(
      tier = "5_fuzzy_like",
      sql  = glue("
        SELECT concept_id, concept_name, domain_id, vocabulary_id,
               standard_concept, concept_code
        FROM {vocab_schema}.concept
        WHERE LOWER(concept_name) LIKE LOWER($1)
          AND standard_concept = 'S'
          AND invalid_reason IS NULL
          AND domain_id = $2
        ORDER BY LENGTH(concept_name)
        LIMIT 1
      "),
      params = list(paste0("%", name, "%"), domain)
    )
  )

  for (tier in tiers) {
    result <- tryCatch(
      DBI::dbGetQuery(conn, tier$sql, params = tier$params),
      error = function(e) {
        warning("Tier ", tier$tier, " query error for '", name, "': ", e$message)
        NULL
      }
    )

    if (!is.null(result) && nrow(result) > 0) {
      result$lookup_tier  <- tier$tier
      result$input_name   <- name
      result$input_domain <- domain
      return(result)
    }
  }

  # Unresolved — return placeholder row for the report
  data.frame(
    concept_id    = NA_integer_,
    concept_name  = NA_character_,
    domain_id     = NA_character_,
    vocabulary_id = NA_character_,
    standard_concept = NA_character_,
    concept_code  = NA_character_,
    lookup_tier   = "unresolved",
    input_name    = name,
    input_domain  = domain,
    stringsAsFactors = FALSE
  )
}


#' Resolve all LLM-generated concept names for one phenotype
#'
#' @param conn         DBI connection
#' @param concepts_df  Data frame from response_parser (concept_name, domain, ...)
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Data frame with all original columns plus resolved concept_id + metadata.
lookup_all_concepts <- function(conn, concepts_df, vocab_schema = "vocab") {

  results <- vector("list", nrow(concepts_df))

  for (i in seq_len(nrow(concepts_df))) {
    row    <- concepts_df[i, ]
    result <- lookup_concept(conn, row$concept_name, row$domain, vocab_schema)

    # Carry forward LLM metadata
    result$is_excluded         <- row$is_excluded
    result$include_descendants <- row$include_descendants
    result$notes               <- row$notes
    results[[i]]               <- result
  }

  out <- dplyr::bind_rows(results)

  n_resolved   <- sum(!is.na(out$concept_id))
  n_unresolved <- sum( is.na(out$concept_id))
  res_rate     <- round(n_resolved / nrow(out) * 100, 1)

  message("  Resolution: ", n_resolved, " / ", nrow(out),
          " (", res_rate, "%)")

  if (n_unresolved > 0) {
    message("  Unresolved names:")
    unresolved_names <- out$input_name[is.na(out$concept_id)]
    for (nm in unresolved_names) message("    - ", nm)
  }

  out
}
