# =============================================================================
# Phase C2 — Run Gemini 2.5 Pro on all 5 phenotypes × 3 trials and merge with
# the existing Claude Opus 4.6 rows. The prior Flash data lives in
# data/results/pipeline_summary_flash.csv (archived; do not use going forward).
#
# Reads:   data/results/pipeline_summary.csv (Opus + old Flash; Flash rows dropped)
# Writes:  data/results/pipeline_summary.csv (Opus + new Pro)
# =============================================================================

library(dotenv)
library(yaml)
library(dplyr)
library(readr)

if (file.exists(".env")) dotenv::load_dot_env(".env")

source("R/pipeline.R")

config        <- load_config("config/db_config.yaml")
pro_cfg       <- Filter(function(m) m$label == "gemini_pro", config$llm$models)[[1]]
all_phenotypes <- config$phenotypes
n_trials      <- config$pipeline$trials_per_cell %||% 3

# 1. Preserve existing Opus rows from pipeline_summary.csv (drop old Flash rows)
existing <- readr::read_csv("data/results/pipeline_summary.csv", show_col_types = FALSE)
opus_rows <- existing |> filter(model == "claude_opus_4_6")
cat("Kept ", nrow(opus_rows), " Claude Opus rows; dropping ",
    nrow(existing) - nrow(opus_rows), " old Gemini Flash rows.\n", sep = "")

# 2. Run Gemini Pro for all phenotypes × all trials
pro_summaries <- list()
total_cells   <- length(all_phenotypes) * n_trials
cell_n        <- 0

for (ph in all_phenotypes) {
  for (trial in seq_len(n_trials)) {
    cell_n <- cell_n + 1
    cat("\n[", cell_n, "/", total_cells, "] ",
        ph$key, " x gemini_pro x trial ", trial, "\n", sep = "")

    result <- tryCatch(
      run_phenotype(ph$key, pro_cfg, config, trial),
      error = function(e) {
        message("  FAILED: ", e$message)
        list(summary = data.frame(
          phenotype = ph$key, model = pro_cfg$label, trial = trial,
          f1 = 0, f1_aa = 0, error = e$message,
          stringsAsFactors = FALSE
        ))
      }
    )
    pro_summaries <- c(pro_summaries, list(result$summary))
  }
}

pro_df <- dplyr::bind_rows(pro_summaries)
cat("\nGemini Pro runs complete: ", nrow(pro_df), " rows.\n", sep = "")

# 3. Merge: Opus (existing) + Pro (new) and persist
merged <- dplyr::bind_rows(opus_rows, pro_df)
out_path <- "data/results/pipeline_summary.csv"
readr::write_csv(merged, out_path)

cat("\n", strrep("=", 65), "\n", sep = "")
cat("Wrote merged Opus + Pro to: ", out_path, " (", nrow(merged), " rows)\n", sep = "")
cat(strrep("=", 65), "\n\n", sep = "")

# Quick patient F1 summary
if ("patient_f1" %in% colnames(merged)) {
  print(merged |>
    group_by(phenotype, model) |>
    summarise(mean_f1 = mean(patient_f1, na.rm = TRUE),
              .groups = "drop") |>
    arrange(phenotype, model))
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
