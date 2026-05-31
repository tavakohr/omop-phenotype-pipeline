# =============================================================================
# Phase 3 — Ancestor Expansion
# For every resolved concept where include_descendants = TRUE, queries
# CONCEPT_ANCESTOR to add all standard descendants.
# This mirrors ATLAS "Include Descendants" checkbox.
# =============================================================================

library(DBI)
library(dplyr)
library(glue)

#' Get all standard descendants of a concept via CONCEPT_ANCESTOR
#'
#' @param conn         DBI connection
#' @param concept_id   Integer. The anchor concept_id.
#' @param max_levels   Integer or NULL. Max levels of separation (NULL = all).
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Data frame of descendant concepts.
get_descendants <- function(conn, concept_id,
                             max_levels   = NULL,
                             vocab_schema = "vocab") {

  level_filter <- if (!is.null(max_levels)) {
    glue("AND ca.min_levels_of_separation <= {max_levels}")
  } else ""

  sql <- glue("
    SELECT c.concept_id,
           c.concept_name,
           c.domain_id,
           c.vocabulary_id,
           c.standard_concept,
           c.concept_code,
           ca.min_levels_of_separation,
           ca.max_levels_of_separation
    FROM {vocab_schema}.concept_ancestor ca
    JOIN {vocab_schema}.concept c
      ON ca.descendant_concept_id = c.concept_id
    WHERE ca.ancestor_concept_id = $1
      AND ca.min_levels_of_separation >= 1
      AND c.standard_concept = 'S'
      AND c.invalid_reason IS NULL
      {level_filter}
    ORDER BY ca.min_levels_of_separation, c.concept_name
  ")

  result <- tryCatch(
    DBI::dbGetQuery(conn, sql, params = list(as.integer(concept_id))),
    error = function(e) {
      warning("Descendant query failed for concept_id ", concept_id,
              ": ", e$message)
      data.frame()
    }
  )

  if (nrow(result) > 0) result$source_ancestor_id <- concept_id
  result
}


#' Expand all concepts with include_descendants = TRUE
#'
#' @param conn         DBI connection
#' @param lookup_df    Data frame from lookup_all_concepts() (resolved rows).
#' @param max_levels   Integer or NULL. Max descendant levels.
#' @param vocab_schema Character. Vocabulary schema name.
#' @return Expanded data frame of all inclusion + exclusion concepts.
expand_concept_set <- function(conn, lookup_df,
                                max_levels   = NULL,
                                vocab_schema = "vocab") {

  # Drop unresolved rows
  resolved <- lookup_df[!is.na(lookup_df$concept_id), ]

  if (nrow(resolved) == 0) {
    warning("No resolved concepts to expand.")
    return(data.frame())
  }

  all_rows <- vector("list", nrow(resolved))

  for (i in seq_len(nrow(resolved))) {
    row <- resolved[i, ]

    # Always include the anchor concept itself
    anchor <- data.frame(
      concept_id               = as.integer(row$concept_id),
      concept_name             = row$concept_name,
      domain_id                = row$domain_id,
      vocabulary_id            = row$vocabulary_id,
      standard_concept         = row$standard_concept,
      concept_code             = row$concept_code,
      is_excluded              = row$is_excluded,
      include_descendants      = row$include_descendants,
      source                   = "anchor",
      levels_from_anchor       = 0L,
      source_ancestor_id       = as.integer(row$concept_id),
      stringsAsFactors         = FALSE
    )

    rows <- list(anchor)

    if (isTRUE(row$include_descendants)) {
      desc <- get_descendants(conn, row$concept_id, max_levels, vocab_schema)

      if (nrow(desc) > 0) {
        desc$is_excluded         <- row$is_excluded
        desc$include_descendants <- FALSE   # descendants don't recurse
        desc$source              <- "descendant"
        desc$levels_from_anchor  <- desc$min_levels_of_separation

        # Keep only columns we need
        keep <- c("concept_id","concept_name","domain_id","vocabulary_id",
                  "standard_concept","concept_code","is_excluded",
                  "include_descendants","source","levels_from_anchor",
                  "source_ancestor_id")
        desc <- desc[, intersect(keep, colnames(desc))]

        rows <- c(rows, list(desc))
      }
    }

    all_rows[[i]] <- dplyr::bind_rows(rows)
  }

  result <- dplyr::bind_rows(all_rows) |>
    dplyr::distinct(concept_id, is_excluded, .keep_all = TRUE)

  n_inc <- sum(!result$is_excluded)
  n_exc <- sum( result$is_excluded)

  message("  Concept set after expansion: ", nrow(result), " total")
  message("    Inclusion: ", n_inc, "  |  Exclusion: ", n_exc)

  result
}
