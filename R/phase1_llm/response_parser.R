# =============================================================================
# Phase 1 — Response Parser
# Parses the raw LLM text response into a clean data frame of concept names.
# Validates that no concept_ids slipped through.
# =============================================================================

library(jsonlite)
library(dplyr)

#' Parse raw LLM response text into a concept name data frame
#'
#' @param raw_text Character. Raw text output from the LLM.
#' @return A data frame with columns:
#'   concept_name, domain, vocabulary_hint, is_excluded,
#'   include_descendants, notes
parse_llm_response <- function(raw_text) {

  # Strip markdown code fences if present
  clean <- gsub("```json\\s*", "", raw_text)
  clean <- gsub("```\\s*$",    "", clean)
  clean <- trimws(clean)

  # Parse JSON
  parsed <- tryCatch(
    jsonlite::fromJSON(clean, simplifyDataFrame = FALSE),
    error = function(e) {
      stop("Failed to parse LLM response as JSON.\nError: ", e$message,
           "\nRaw text (first 500 chars):\n",
           substr(raw_text, 1, 500))
    }
  )

  if (is.null(parsed$concepts) || length(parsed$concepts) == 0) {
    stop("LLM response JSON contained no 'concepts' array.")
  }

  # Convert list of concepts to data frame
  concepts_df <- dplyr::bind_rows(
    lapply(parsed$concepts, function(c) {
      data.frame(
        concept_name        = as.character(c$concept_name      %||% NA),
        domain              = as.character(c$domain             %||% "Condition"),
        vocabulary_hint     = as.character(c$vocabulary_hint    %||% "SNOMED"),
        is_excluded         = as.logical(c$is_excluded          %||% FALSE),
        include_descendants = as.logical(c$include_descendants  %||% TRUE),
        notes               = as.character(c$notes              %||% ""),
        stringsAsFactors    = FALSE
      )
    })
  )

  # Safety check: reject any concept_name that looks like a bare integer (concept_id)
  looks_like_id <- grepl("^\\d{5,}$", trimws(concepts_df$concept_name))
  if (any(looks_like_id)) {
    bad <- concepts_df$concept_name[looks_like_id]
    stop("LLM output contained raw concept_id integers (not allowed): ",
         paste(bad, collapse = ", "),
         "\nThe LLM must output concept NAMES only.")
  }

  # Drop rows with missing concept names
  concepts_df <- concepts_df[!is.na(concepts_df$concept_name) &
                               nchar(trimws(concepts_df$concept_name)) > 0, ]

  message("  Parsed ", nrow(concepts_df), " concept names from LLM response ",
          "(", sum(concepts_df$is_excluded), " exclusions, ",
          sum(!concepts_df$is_excluded), " inclusions)")

  concepts_df
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
