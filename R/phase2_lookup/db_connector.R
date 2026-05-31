# =============================================================================
# Phase 2 — Database Connector
# Opens a DBI connection to PostgreSQL using config/db_config.yaml
# =============================================================================

library(DBI)
library(RPostgres)
library(yaml)
library(dotenv)

#' Load database config from YAML
#'
#' @param config_path Path to db_config.yaml
#' @return Named list of config values
load_config <- function(config_path = "config/db_config.yaml") {
  if (!file.exists(config_path)) {
    stop("Config file not found: ", config_path)
  }
  yaml::read_yaml(config_path)
}

#' Open a PostgreSQL connection
#'
#' @param config List returned by load_config()
#' @return DBI connection object
connect_db <- function(config) {
  # Load .env if present
  if (file.exists(".env")) dotenv::load_dot_env(".env")

  db <- config$database

  # Allow env var overrides (useful in CI)
  host     <- Sys.getenv("DB_HOST",     unset = db$host)
  port     <- as.integer(Sys.getenv("DB_PORT", unset = db$port))
  dbname   <- Sys.getenv("DB_NAME",     unset = db$dbname)
  user     <- Sys.getenv("DB_USER",     unset = db$user)
  password <- Sys.getenv("DB_PASSWORD", unset = db$password)

  conn <- DBI::dbConnect(
    RPostgres::Postgres(),
    host     = host,
    port     = port,
    dbname   = dbname,
    user     = user,
    password = password
  )

  message("Connected to PostgreSQL: ", dbname, " @ ", host, ":", port)
  conn
}

#' Quick connection test — verifies vocabulary tables exist and are populated
#'
#' @param conn DBI connection
#' @param vocab_schema Character. Name of vocabulary schema.
verify_connection <- function(conn, vocab_schema = "vocab") {
  required_tables <- c("concept", "concept_ancestor",
                        "concept_relationship", "concept_synonym")

  for (tbl in required_tables) {
    n <- DBI::dbGetQuery(
      conn,
      glue::glue("SELECT COUNT(*) AS n FROM {vocab_schema}.{tbl}")
    )$n
    message("  ", vocab_schema, ".", tbl, ": ", format(n, big.mark = ","), " rows")
  }
}
