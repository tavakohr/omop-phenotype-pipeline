# =============================================================================
# Tests — Concept Lookup
# Run with: testthat::test_file("tests/test_concept_lookup.R")
# Requires a live DB connection. Set env vars before running.
# =============================================================================

library(testthat)
source("R/phase2_lookup/db_connector.R")
source("R/phase2_lookup/concept_lookup.R")

# Skip all tests if DB is not reachable
skip_if_no_db <- function() {
  tryCatch({
    config <- load_config()
    conn   <- connect_db(config)
    DBI::dbDisconnect(conn)
    FALSE
  }, error = function(e) {
    skip("Database not reachable — skipping DB-dependent tests.")
  })
}

test_that("lookup_concept resolves 'Type 2 diabetes mellitus' exactly", {
  skip_if_no_db()
  config <- load_config()
  conn   <- connect_db(config)
  on.exit(DBI::dbDisconnect(conn))

  result <- lookup_concept(conn, "Type 2 diabetes mellitus", "Condition",
                            vocab_schema = config$database$vocab_schema)

  expect_false(is.na(result$concept_id))
  expect_equal(result$standard_concept, "S")
  expect_equal(result$domain_id, "Condition")
  expect_match(result$lookup_tier, "^1_")  # should resolve on first tier
})

test_that("lookup_concept returns unresolved row for gibberish name", {
  skip_if_no_db()
  config <- load_config()
  conn   <- connect_db(config)
  on.exit(DBI::dbDisconnect(conn))

  result <- lookup_concept(conn, "xyzzy_not_a_real_concept_zzz", "Condition",
                            vocab_schema = config$database$vocab_schema)

  expect_true(is.na(result$concept_id))
  expect_equal(result$lookup_tier, "unresolved")
})

test_that("lookup_concept resolves 'Metformin' in Drug domain", {
  skip_if_no_db()
  config <- load_config()
  conn   <- connect_db(config)
  on.exit(DBI::dbDisconnect(conn))

  result <- lookup_concept(conn, "Metformin", "Drug",
                            vocab_schema = config$database$vocab_schema)

  expect_false(is.na(result$concept_id))
  expect_equal(result$standard_concept, "S")
  expect_equal(result$domain_id, "Drug")
})

test_that("lookup_all_concepts handles a mixed list correctly", {
  skip_if_no_db()
  config <- load_config()
  conn   <- connect_db(config)
  on.exit(DBI::dbDisconnect(conn))

  concepts_df <- data.frame(
    concept_name        = c("Type 2 diabetes mellitus", "Metformin",
                             "totally_fake_concept_xyz"),
    domain              = c("Condition", "Drug", "Condition"),
    vocabulary_hint     = c("SNOMED", "RxNorm", "SNOMED"),
    is_excluded         = c(FALSE, FALSE, FALSE),
    include_descendants = c(TRUE, TRUE, FALSE),
    notes               = c("", "", ""),
    stringsAsFactors    = FALSE
  )

  result <- lookup_all_concepts(conn, concepts_df,
                                 vocab_schema = config$database$vocab_schema)

  expect_equal(nrow(result), 3)
  expect_equal(sum(!is.na(result$concept_id)), 2)   # 2 resolved
  expect_equal(sum( is.na(result$concept_id)), 1)   # 1 unresolved
})
