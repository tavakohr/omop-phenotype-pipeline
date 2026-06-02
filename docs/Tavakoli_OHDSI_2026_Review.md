# Reviewer Comments — Tavakoli et al., OHDSI 2026 Brief Report

**Manuscript:** *Patient-level evaluation of LLM-assisted OMOP phenotype curation: a benchmark against expert gold standards on MIMIC-IV*

**Reviewer perspective:** OHDSI community / medical informatics & AI

**Recommendation:** Major revision — the core idea is valuable, but the central claim is not yet defensible as written, and several numbers do not reconcile.

---

## 1. Critical issue — the headline finding may be an artifact, not a discovery

The paper rests on one contrast: patient-level F1 ≈ 0.91 versus ancestor-aware concept-level F1 ≈ 0.45, presented as proof that concept-overlap metrics "underestimate real-world value." Two interlocking problems make this contrast non-informative as currently framed.

### 1a. The "gold standard" is not a true gold standard
The title and conclusion claim a benchmark against "expert gold standards" tested on "actual patient data." However, the patient-level reference cohort is itself derived from an OHDSI **concept set** executed against MIMIC-IV (Table 1 footnote: patients "flagged by the OHDSI inclusion concept set after seed expansion via concept_ancestor"). This compares one automated concept set against another automated concept set on the same data — a **silver standard**, not clinician-adjudicated cases. The framing materially overstates what was validated.

### 1b. The two metrics are expected to diverge for a structural reason not addressed
Both the gold and LLM concept sets are expanded through `concept_ancestor` (Phase 3, and the gold "after seed expansion"). In coded EHR data, one or two high-level seed concepts plus descendant expansion captures almost the entire patient set — exactly the "Diabetes mellitus" example in the Introduction. Consequently **many different concept sets collapse to nearly the same patient set.** High patient-level recall (recall = 1.00 in four cells) is therefore the *expected* behavior, not evidence of hidden LLM competence.

- The abstract reads the ~2× gap as "the patient metric reveals value the concept metric misses."
- A skeptical reviewer reads the same gap as "the patient metric is **insensitive** — it saturates on common codes and cannot discriminate."

The second interpretation must be ruled out. Concretely:
- Report a **trivial-seed baseline**: a single obvious seed concept per phenotype (e.g., only "Type 2 diabetes mellitus") with descendant expansion. If that baseline already scores ~0.9 patient F1, the LLM's marginal contribution is small and the headline collapses.
- Add **prevalence context**: patient F1 is only meaningful where the gold cohort is a database minority. In an ICU sample, T2DM and treatment-resistant depression are not rare, inflating overlap.

---

## 2. Near-critical issue — per-phenotype manual engineering contradicts "no special training"

The two "phenotype-aware design features" are bespoke human inputs, not LLM output:
- The **entire measurement domain** was manually excluded from cohort queries.
- For acute liver injury and drug-induced pancreatitis (two of the hardest phenotypes), briefs "explicitly enumerated alcohol-related, viral-hepatitis, biliary, and gastrointestinal-obstruction concepts" — i.e., a physician hand-coded the exclusion logic into the prompt.

Therefore the conclusion that the AI was "highly accurate … without any special training" is not supported by the methods: the difficult cases received tailored human scaffolding. This is a confound that must be owned in the wording (e.g., "with lightweight, physician-authored exclusion guidance" rather than "without any special training").

---

## 3. Major issues (fixable, but currently undermine credibility)

### 3a. Numeric inconsistencies / data integrity
These are checkable and would justify desk rejection if left uncorrected:

| Location | Stated | Correct / issue |
|---|---|---|
| Concept-level F1 (text vs Table 1) | 0.38 (text) | **0.45** (table mean of the ten cell values is 0.451) |
| "2.4 times higher" | 2.4× | Computed from the erroneous 0.38; with 0.45 it is **~2.0×** |
| "Six cells … F1 ≥ 0.92" | 6 | **7** cells (0.99, 0.97, 0.96, 0.95, 0.94, 0.92, 0.92) |
| "Four exceeded 0.95" | 4 | Only **3** *exceed* 0.95 (0.99, 0.97, 0.96); 0.95 does not exceed itself |
| Diabetes-Claude sentence | "recall = 0.94." | **Truncated, unclosed parenthesis**; sentence ends mid-clause |

### 3b. "30 cells" vs "10 cells"
The text says "yielding 30 cells" and "across all 30 cells," but a cell is phenotype × model = **10 cells**, each a mean of 3 trials (**30 runs**). The Mean row averages 10 cells. Use the terminology consistently (10 cells / 30 runs).

### 3c. No inferential statistics on the model comparison
"Claude outperformed Gemini by ~four percentage points (0.93 vs 0.89)" with n = 5 phenotypes and 3 trials is reported with no test and no confidence intervals. This sample cannot support a real-difference claim. Either soften to descriptive language or add a paired test across phenotypes with CIs.

### 3d. Unfair model pairing
The comparison is **Claude Opus 4.6** (frontier/large tier) against **Gemini 2.5 Flash** (Google's small, low-cost tier). Concluding Claude is superior is apples-to-oranges; the fair comparator is Gemini 2.5 Pro. As written the cross-model claim is not defensible.

### 3e. Phenotype logic is stripped
Two phenotypes are *algorithmic*, not concept-set membership:
- "Cardiac valve surgery **with new-onset** atrial fibrillation" is temporal (AF arising *after* surgery).
- "Treatment-resistant depression" requires ≥2 failed treatment lines.

Collapsing these to "patients flagged by the inclusion concept set" discards the cohort logic that defines them, so for these phenotypes the study is not evaluating phenotype curation. State explicitly that the evaluation is of **concept-set membership**, not full OHDSI cohort definitions, and consider dropping or reframing the temporal phenotypes.

### 3f. Single-center ICU generalizability
MIMIC-IV is one ICU/ED population. The measurement-domain exclusion is justified by "incidental laboratory orders common in ICU populations" — a dataset-specific workaround. The conclusion ("highly accurate across all five conditions") generalizes well beyond what one idiosyncratic ICU sample supports.

---

## 4. Suggested improvements (priority order)

1. **Reframe the gold standard honestly** in title and text: "against OHDSI Phenotype Library concept-set–derived cohorts," not "expert gold standards" / "actual patient data."
2. **Add the trivial-seed baseline** so readers can separate genuine LLM skill from ancestor-expansion saturation. This single change would most strengthen the paper.
3. **Reconcile every number**: 0.45 not 0.38; recompute the multiplier; fix 6 → 7 and the > 0.95 count; close the diabetes sentence; fix 30 → 10 cells.
4. **Rewrite the conclusion** to acknowledge the physician-authored exclusion briefs ("with lightweight expert guidance") and scope the generalization to a coded ICU database pending external replication.
5. **Fix or drop the cross-model claim**: use a same-tier Gemini (2.5 Pro) and add a paired test with confidence intervals.
6. **Clarify the unit of evaluation** — concept-set membership, not temporal/algorithmic cohort logic — and reconsider the two phenotypes whose definitions cannot be reproduced without cohort logic.

---

## 5. Summary table of issues

| # | Severity | Issue | Required action |
|---|---|---|---|
| 1a | Critical | Patient-level "gold standard" is concept-set–derived, not adjudicated | Reframe as silver standard |
| 1b | Critical | High patient F1 may be an ancestor-expansion saturation artifact | Add trivial-seed baseline |
| 2 | Near-critical | "No special training" contradicted by manual per-phenotype briefs | Reword to acknowledge expert guidance |
| 3a | Major | Numeric inconsistencies (0.38 vs 0.45, 2.4×, cell counts, truncated sentence) | Correct all figures |
| 3b | Major | "30 cells" vs 10 cells terminology | Standardize (10 cells / 30 runs) |
| 3c | Major | No statistics on Claude-vs-Gemini difference | Add paired test + CIs or soften |
| 3d | Major | Opus vs Flash is an unfair tier mismatch | Compare to Gemini 2.5 Pro |
| 3e | Major | Temporal/algorithmic phenotypes reduced to concept-set membership | State scope; reconsider those phenotypes |
| 3f | Major | Single ICU dataset over-generalized | Scope claims; flag external validation |

---

*Prepared as peer-review feedback. The underlying contribution — evaluating LLM-curated concept sets at the patient level rather than by term overlap — is worthwhile; the issues above concern validity framing, statistical support, and internal consistency, all of which are addressable in revision.*
