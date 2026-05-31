# =============================================================================
# ENTRY POINT — Run the full pipeline
# Runs all phenotypes × all models × N trials and saves results.
#
# Usage (from project root):
#   source("scripts/run_pipeline.R")
#   # or from terminal:
#   Rscript scripts/run_pipeline.R
#   Rscript scripts/run_pipeline.R --phenotype t2dm --model claude_opus_4_6
# =============================================================================

library(dotenv)
library(yaml)
library(dplyr)
library(readr)

# Load .env for API keys
if (file.exists(".env")) dotenv::load_dot_env(".env")

# Source orchestrator
source("R/pipeline.R")

# ── Parse command-line arguments (optional) ───────────────────────────────────
args <- commandArgs(trailingOnly = TRUE)

filter_phenotype <- NULL
filter_model     <- NULL

i <- 1
while (i <= length(args)) {
  if (args[i] == "--phenotype" && i < length(args)) {
    filter_phenotype <- args[i + 1]; i <- i + 2
  } else if (args[i] == "--model" && i < length(args)) {
    filter_model <- args[i + 1]; i <- i + 2
  } else {
    i <- i + 1
  }
}

# ── Load config ───────────────────────────────────────────────────────────────
config       <- load_config("config/db_config.yaml")
all_models   <- config$llm$models
all_phenotypes <- config$phenotypes
n_trials     <- config$pipeline$trials_per_cell %||% 3

# Apply filters if specified
if (!is.null(filter_phenotype)) {
  all_phenotypes <- Filter(function(p) p$key == filter_phenotype, all_phenotypes)
  if (length(all_phenotypes) == 0) stop("Phenotype '", filter_phenotype, "' not found in config.")
}
if (!is.null(filter_model)) {
  all_models <- Filter(function(m) m$label == filter_model, all_models)
  if (length(all_models) == 0) stop("Model '", filter_model, "' not found in config.")
}

# ── Run ───────────────────────────────────────────────────────────────────────
all_summaries <- list()
failed        <- list()

total_cells <- length(all_phenotypes) * length(all_models) * n_trials
cell_n      <- 0

for (ph in all_phenotypes) {
  for (mdl in all_models) {
    for (trial in seq_len(n_trials)) {

      cell_n <- cell_n + 1
      cat("\n[", cell_n, "/", total_cells, "] ",
          ph$key, " × ", mdl$label, " × trial ", trial, "\n", sep = "")

      result <- tryCatch(
        run_phenotype(ph$key, mdl, config, trial),
        error = function(e) {
          message("  ✗ FAILED: ", e$message)
          list(summary = data.frame(
            phenotype = ph$key, model = mdl$label, trial = trial,
            f1 = 0, f1_aa = 0, error = e$message,
            stringsAsFactors = FALSE
          ))
        }
      )

      all_summaries <- c(all_summaries, list(result$summary))
    }
  }
}

# ── Save results ──────────────────────────────────────────────────────────────
dir.create("data/results", showWarnings = FALSE, recursive = TRUE)

summary_df <- dplyr::bind_rows(all_summaries)
out_path   <- "data/results/pipeline_summary.csv"
readr::write_csv(summary_df, out_path)

cat("\n", strrep("=", 65), "\n")
cat("RESULTS SAVED TO:", out_path, "\n")
cat(strrep("=", 65), "\n\n")

# Print summary table
if (nrow(summary_df) > 0) {
  cols <- intersect(c("phenotype","model","trial","f1","f1_aa","resolution_rate"),
                    colnames(summary_df))
  print(summary_df[, cols])

  cat("\nMean F1 by model:\n")
  if ("f1" %in% colnames(summary_df)) {
    means <- summary_df |>
      group_by(model) |>
      summarise(mean_f1 = mean(f1, na.rm = TRUE),
                mean_f1_aa = mean(f1_aa, na.rm = TRUE),
                .groups = "drop")
    print(means)
  }
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
