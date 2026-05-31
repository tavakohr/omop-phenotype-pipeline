# =============================================================================
# Phase 1 — Prompt Builder
# Constructs the LLM prompt from a physician brief text file.
# The LLM must NEVER output concept_ids — names and metadata only.
# =============================================================================

SYSTEM_PROMPT <- '
You are a clinical informatician helping build OMOP CDM concept sets.
You will receive a physician\'s phenotype brief and must output a structured
list of clinical concept names that represent the phenotype.

STRICT RULES:
1. Do NOT output any concept_id integers. Concept NAMES only.
2. Set is_excluded = true ONLY when the brief explicitly uses "exclude",
   "no prior", "without", or "not" for that concept. Never use is_excluded
   for differential-diagnosis reasoning.
3. Set include_descendants = true SPARINGLY — only for AT MOST 5 broad anchor
   concepts per phenotype (typically the umbrella disease term and the major
   drug class umbrellas). For all individual drug ingredients, specific disease
   subtypes, specific procedures, and exact measurement codes, set
   include_descendants = false. Over-using include_descendants causes the
   concept set to explode by 3-5 orders of magnitude and destroys precision.
4. Cover ALL vocabulary domains in the brief: if it mentions conditions,
   drugs, AND labs, include concepts from Condition, Drug, AND Measurement.
5. For drug phenotypes: enumerate INDIVIDUAL drug ingredient names.
   Write "Metformin", "Glipizide", "Sitagliptin" — not "antidiabetic drugs".
6. Output valid JSON only. No prose before or after the JSON block.

OUTPUT JSON SCHEMA:
{
  "phenotype_name": "string",
  "concepts": [
    {
      "concept_name": "string — clinical term as in SNOMED / RxNorm / LOINC",
      "domain": "Condition | Drug | Measurement | Procedure | Observation",
      "vocabulary_hint": "SNOMED | RxNorm | LOINC | CPT4",
      "is_excluded": false,
      "include_descendants": true,
      "notes": "brief rationale"
    }
  ],
  "temporal_qualifiers_not_captured": "string — any temporal logic that
    must be implemented in ATLAS cohort criteria, not in the concept set"
}
'

#' Build the full prompt to send to the LLM
#'
#' @param brief_path   Path to the physician brief .txt file.
#' @param max_concepts Target number of concepts to generate (higher = better recall).
#' @return Character. Complete prompt string.
build_prompt <- function(brief_path, max_concepts = 100) {
  if (!file.exists(brief_path)) {
    stop("Physician brief not found: ", brief_path)
  }

  brief_text <- paste(readLines(brief_path, warn = FALSE), collapse = "\n")

  glue::glue(
    "{SYSTEM_PROMPT}\n\n",
    "TARGET CONCEPT COUNT: aim for {max_concepts} concepts.\n",
    "More is better for recall — the SQL lookup handles resolution.\n",
    "Be exhaustive rather than conservative.\n\n",
    "PHYSICIAN BRIEF:\n---\n{brief_text}\n---\n\n",
    "Output the JSON concept list now:"
  )
}
