# =============================================================================
# Extract Gold Standards from OHDSI PhenotypeLibrary
# Run this script ONCE to download and save gold-standard concept sets.
#
# Requirements:
#   remotes::install_github("OHDSI/PhenotypeLibrary")
#   remotes::install_github("OHDSI/CirceR")
# =============================================================================

if (!requireNamespace("PhenotypeLibrary", quietly = TRUE)) {
  message("Installing PhenotypeLibrary from OHDSI GitHub...")
  remotes::install_github("OHDSI/PhenotypeLibrary")
}

library(PhenotypeLibrary)
library(jsonlite)
library(dplyr)

dir.create("data/gold_standards", showWarnings = FALSE, recursive = TRUE)

# ── Phenotypes to extract ─────────────────────────────────────────────────────
# cohortId matches OHDSI Phenotype Library v3.36.0
phenotypes <- list(
  list(key = "t2dm",              cohort_id = 288,   file = "p01_t2dm.json"),
  list(key = "cardiac_valve_af",  cohort_id = 1103, file = "p02_cardiac_valve_af.json"),
  list(key = "acute_liver_injury",cohort_id = 736,  file = "p03_acute_liver_injury.json"),
  list(key = "drug_pancreatitis", cohort_id = 253,  file = "p04_drug_pancreatitis.json"),
  list(key = "trd",               cohort_id = 1009, file = "p05_trd.json")
  # Add new phenotypes here:
  # list(key = "hypertension", cohort_id = XXXX, file = "p07_hypertension.json")
)

# ── Extraction loop ───────────────────────────────────────────────────────────
for (ph in phenotypes) {
  message("\nExtracting: ", ph$key, " (cohortId = ", ph$cohort_id, ")")

  tryCatch({
    # Get cohort definition set
    cohort_def <- PhenotypeLibrary::getPlCohortDefinitionSet(
      cohortIds = ph$cohort_id
    )

    # Parse the Circe JSON definition to extract concept sets
    circe_json <- cohort_def$json[1]
    parsed     <- jsonlite::fromJSON(circe_json, simplifyDataFrame = FALSE)

    # Extract all concept set items
    all_items <- list()
    for (cs in parsed$ConceptSets) {
      for (item in cs$expression$items) {
        all_items <- c(all_items, list(list(
          concept_id          = item$concept$CONCEPT_ID,
          concept_name        = item$concept$CONCEPT_NAME,
          standard_concept    = item$concept$STANDARD_CONCEPT,
          domain_id           = item$concept$DOMAIN_ID,
          vocabulary_id       = item$concept$VOCABULARY_ID,
          concept_set_name    = cs$name,
          is_excluded         = isTRUE(item$isExcluded),
          include_descendants = isTRUE(item$includeDescendants),
          include_mapped      = isTRUE(item$includeMapped)
        )))
      }
    }

    all_df <- dplyr::bind_rows(lapply(all_items, as.data.frame))

    # Gold standard = standard concepts, NOT excluded
    gold_ids <- all_df$concept_id[
      all_df$standard_concept == "S" & !all_df$is_excluded
    ]

    excluded_ids <- all_df$concept_id[all_df$is_excluded]

    output <- list(
      cohort_id          = ph$cohort_id,
      cohort_name        = ph$key,
      cohort_description = cohort_def$cohortName[1],
      gold_concept_ids   = as.integer(unique(gold_ids)),
      excluded_concept_ids = as.integer(unique(excluded_ids)),
      n_gold             = length(unique(gold_ids)),
      n_excluded         = length(unique(excluded_ids)),
      all_items          = all_items
    )

    out_path <- file.path("data/gold_standards", ph$file)
    jsonlite::write_json(output, out_path, pretty = TRUE, auto_unbox = TRUE)

    message("  Saved: ", out_path)
    message("  Gold concepts (inclusion): ", output$n_gold)
    message("  Exclusion concepts:        ", output$n_excluded)

  }, error = function(e) {
    warning("Failed to extract ", ph$key, ": ", e$message)
  })
}

message("\nDone. Gold standards saved to data/gold_standards/")
message("Verify with: list.files('data/gold_standards')")
