# =============================================================================
# Tests — Scorer (no DB required for exact_score tests)
# Run with: testthat::test_file("tests/test_scorer.R")
# =============================================================================

library(testthat)
source("R/evaluation/scorer.R")

test_that("exact_score: perfect match", {
  s <- exact_score(c(1L, 2L, 3L), c(1L, 2L, 3L))
  expect_equal(s["precision"], c(precision = 1))
  expect_equal(s["recall"],    c(recall    = 1))
  expect_equal(s["f1"],        c(f1        = 1))
  expect_equal(s["jaccard"],   c(jaccard   = 1))
})

test_that("exact_score: no overlap", {
  s <- exact_score(c(1L, 2L), c(3L, 4L))
  expect_equal(unname(s["f1"]),  0)
  expect_equal(unname(s["tp"]),  0)
  expect_equal(unname(s["fp"]),  2)
  expect_equal(unname(s["fn"]),  2)
})

test_that("exact_score: partial overlap", {
  s <- exact_score(c(1L, 2L, 3L), c(2L, 3L, 4L))
  # TP=2, FP=1, FN=1
  expect_equal(unname(s["tp"]), 2)
  expect_equal(unname(s["fp"]), 1)
  expect_equal(unname(s["fn"]), 1)
  expect_equal(unname(s["precision"]), 2/3)
  expect_equal(unname(s["recall"]),    2/3)
})

test_that("exact_score: empty predicted", {
  s <- exact_score(integer(0), c(1L, 2L))
  expect_equal(unname(s["precision"]), 0)
  expect_equal(unname(s["recall"]),    0)
  expect_equal(unname(s["f1"]),        0)
})

test_that("exact_score: empty gold", {
  s <- exact_score(c(1L, 2L), integer(0))
  expect_equal(unname(s["recall"]), 0)
  expect_equal(unname(s["f1"]),     0)
})

test_that("exact_score: deduplicates concept_ids", {
  s <- exact_score(c(1L, 1L, 2L), c(1L, 2L))   # duplicate prediction
  expect_equal(unname(s["tp"]), 2)
  expect_equal(unname(s["fp"]), 0)
})
