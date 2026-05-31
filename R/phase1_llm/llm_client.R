# =============================================================================
# Phase 1 — LLM Client
# Supports: Claude Opus 4.6 (Anthropic) and Gemini 2.5 Flash (Google)
#
# Usage:
#   result <- call_llm(prompt, provider = "anthropic", model = "claude-opus-4-6")
#   result <- call_llm(prompt, provider = "gemini",    model = "gemini-2.5-flash")
# =============================================================================

library(httr2)
library(jsonlite)

#' Call an LLM and return the raw text response
#'
#' @param prompt      Character. The full prompt string.
#' @param provider    Character. "anthropic" or "gemini".
#' @param model       Character. Model identifier string.
#' @param temperature Numeric. 0.0 = deterministic.
#' @param max_tokens  Integer. Maximum output tokens.
#' @return Character. Raw text response from the model.
call_llm <- function(prompt,
                     provider    = "anthropic",
                     model       = "claude-opus-4-6",
                     temperature = 0.0,
                     max_tokens  = 8192) {

  provider <- tolower(provider)

  if (provider == "anthropic") {
    call_claude(prompt, model, temperature, max_tokens)
  } else if (provider == "gemini") {
    call_gemini(prompt, model, temperature, max_tokens)
  } else {
    stop("Unknown provider: '", provider, "'. Use 'anthropic' or 'gemini'.")
  }
}


# -----------------------------------------------------------------------------
# Claude (Anthropic)
# Docs: https://docs.anthropic.com/en/api/messages
# -----------------------------------------------------------------------------

call_claude <- function(prompt, model, temperature, max_tokens) {
  api_key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (nchar(api_key) == 0) stop("ANTHROPIC_API_KEY is not set in environment.")

  body <- list(
    model      = model,
    max_tokens = max_tokens,
    messages   = list(list(role = "user", content = prompt))
  )
  # Some newer Claude models (e.g. Opus 4.8+) deprecate the `temperature`
  # parameter — omit when caller passes NULL.
  if (!is.null(temperature)) {
    body$temperature <- temperature
  }

  resp <- request("https://api.anthropic.com/v1/messages") |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = "2023-06-01",
      "content-type"      = "application/json"
    ) |>
    req_body_json(body) |>
    req_error(is_error = \(r) FALSE) |>   # handle errors manually below
    req_perform()

  if (resp_status(resp) != 200) {
    body <- resp_body_string(resp)
    stop("Anthropic API error (", resp_status(resp), "): ", body)
  }

  body <- resp_body_json(resp)

  # Extract text from the first content block
  if (is.null(body$content) || length(body$content) == 0) {
    stop("Claude response contained no content blocks.")
  }

  body$content[[1]]$text
}


# -----------------------------------------------------------------------------
# Gemini (Google)
# Docs: https://ai.google.dev/api/generate-content
# -----------------------------------------------------------------------------

call_gemini <- function(prompt, model, temperature, max_tokens) {
  api_key <- Sys.getenv("GEMINI_API_KEY")
  if (nchar(api_key) == 0) stop("GEMINI_API_KEY is not set in environment.")

  url <- paste0(
    "https://generativelanguage.googleapis.com/v1beta/models/",
    model, ":generateContent"
  )

  resp <- request(url) |>
    req_url_query(key = api_key) |>
    req_headers("content-type" = "application/json") |>
    req_body_json(list(
      contents = list(
        list(parts = list(list(text = prompt)))
      ),
      generationConfig = list(
        temperature      = temperature,
        maxOutputTokens  = max_tokens,
        responseMimeType = "application/json",
        thinkingConfig   = list(thinkingBudget = 0)
      )
    )) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()

  if (resp_status(resp) != 200) {
    body <- resp_body_string(resp)
    stop("Gemini API error (", resp_status(resp), "): ", body)
  }

  body <- resp_body_json(resp)

  if (is.null(body$candidates) || length(body$candidates) == 0) {
    finish <- body$candidates[[1]]$finishReason %||% "UNKNOWN"
    stop("Gemini returned no candidates. finishReason: ", finish)
  }

  # Check for truncation
  finish_reason <- body$candidates[[1]]$finishReason
  if (!is.null(finish_reason) && finish_reason == "MAX_TOKENS") {
    warning("Gemini hit MAX_TOKENS — output may be truncated.")
  }

  body$candidates[[1]]$content$parts[[1]]$text
}


# Helper: null-coalescing operator
`%||%` <- function(a, b) if (!is.null(a)) a else b
