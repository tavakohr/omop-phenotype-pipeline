# =============================================================================
# Phase 2 — Lookup Report
# Summarises which concept names resolved and which need manual review.
# =============================================================================

library(dplyr)

#' Generate and print a lookup resolution report
#'
#' @param lookup_df    Data frame returned by lookup_all_concepts()
#' @param phenotype    Character. Phenotype label for display.
#' @return Named list with summary statistics.
generate_lookup_report <- function(lookup_df, phenotype = "") {

  n_total      <- nrow(lookup_df)
  n_resolved   <- sum(!is.na(lookup_df$concept_id))
  n_unresolved <- sum( is.na(lookup_df$concept_id))
  res_rate     <- round(n_resolved / n_total * 100, 1)

  # Tier distribution for resolved concepts
  tier_counts <- lookup_df |>
    filter(!is.na(concept_id)) |>
    count(lookup_tier, sort = TRUE)

  message("\n--- Lookup Report: ", phenotype, " ---")
  message("  Total concepts:  ", n_total)
  message("  Resolved:        ", n_resolved, " (", res_rate, "%)")
  message("  Unresolved:      ", n_unresolved)

  if (nrow(tier_counts) > 0) {
    message("  Resolution by tier:")
    for (i in seq_len(nrow(tier_counts))) {
      message("    ", tier_counts$lookup_tier[i], ": ", tier_counts$n[i])
    }
  }

  if (n_unresolved > 0) {
    message("  ⚠ Unresolved — check ATHENA manually:")
    unresolved <- lookup_df |> filter(is.na(concept_id))
    for (nm in unresolved$input_name) {
      message("    - ", nm, "  (domain: ",
              unresolved$input_domain[unresolved$input_name == nm][1], ")")
    }
    message("  → Open https://athena.ohdsi.org and search for each name above.")
    message("  → If found, add the correct concept_id to a manual overrides CSV.")
  }

  list(
    phenotype       = phenotype,
    total           = n_total,
    resolved        = n_resolved,
    unresolved      = n_unresolved,
    resolution_rate = res_rate,
    tier_counts     = tier_counts,
    unresolved_names = lookup_df$input_name[is.na(lookup_df$concept_id)]
  )
}
