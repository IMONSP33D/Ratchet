# ACTIVE-LESSONS.md — the currently binding process ruleset

> **Owner: the loop. Read at the start of every run, by the orchestrator, before Stage 1.**
> This is the ONLY learning-loop file any agent reads. Hard cap `CAP_ACTIVE_LESSONS_LINES` = **100
> lines**, because its length is a cost paid on every future run forever. Rewritten only at a
> consolidation (`_TEMPLATE-consolidated.md`); a run's retro proposes changes, it does not apply them.

## Provenance — these are SEEDED, not locally earned

The ten lessons below are filed as **run-000**. They were distilled from a **predecessor pipeline's
nine-run corpus**, not from this repository. A fresh Ratchet deployment therefore starts pre-taught
rather than paying the same nine runs of tuition — but pre-taught is weaker than measured, and the
distinction matters when you rank:

- **Recurrence counts in `(...)` are the predecessor's**, kept for citation, and are NOT local evidence.
  Never increment a seeded count from a local incident: file the incident as its own named lesson at
  `n=1` and let the consolidation merge them by identity.
- **The first local consolidation MUST re-evaluate all ten** against local evidence — confirm with a
  local instance, demote to `watch`, or drop with a reason. A seeded lesson still here at the second
  consolidation with zero local instances is padding. Any of these may be wrong for this project.
- **Every seeded name validates** under both `rt_name_valid` and
  `check_narrative.py --validate-name`. Two were renamed before first filing
  (`availability-before-security`, `settled-ruling-needs-a-home`); a name is permanent
  from its first filing, so renaming after this point is not available - supersede instead.

## How to read a lesson

Each lesson is a **name** (§6 doctrine: kebab-case, permanent, never reused, never renamed), a
one-line statement, the evidence in ≤15 words with its source-corpus id, and `assert:` — the test in
`.claude/hooks/test_hooks.py` that **FAILS when the lesson recurs**. `check_done.py` reads the whole
block for `assert:`, not one physical line. A lesson without a drivable `assert:` is being
*remembered*, and remembering does not hold. A named test never driven with a **mismatched payload
requiring the opposite verdict** is not evidence either — that is `reader-writer-drift`, and it is why
every MUST-FIX below recurred at least once in the source corpus *with its named test green*.

## MUST-FIX — the process has failed these ways repeatedly

### budget-work-not-wall-clock
Budget a run on accumulated WORK seconds with idle folded out; wall-clock across human absence is not effort.
Evidence: five run-ends at 211%–3472% of cap while measured work never exceeded 49% (corpus L-19, n=8).
`assert: TestBudgetCountsWorkNotWall`

### gate-blames-wrong-actor
A gate may only attribute to an actor what that actor provably wrote; below `exact` mode it reports, never orders a revert.
Evidence: seven agents ordered to revert the human's own Tier 2b files; all seven refused (corpus L-13, n=9).
`assert: TestAttributionOnlyBlamesTheActor`

### availability-before-security
The control layer is an availability surface before it is a security surface, and it cannot repair itself — its defects have MTTR = human availability.
Evidence: five of five runs died in the control layer, never in the engineering (corpus L-03 n=9, L-20).
`assert: TestControlLayerIsAvailable`

### decide-by-effect-not-verb
A rule protecting a path decides on write EFFECT — redirects, copy/move/link, `sed -i`, `tee`, `dd`, heredocs — and orders those checks BEFORE any read carve-out.
Evidence: `cat x > LIVE_CONFIRMED` allowed; three rules named a path, then decided by verb (corpus L-11, n=7).
`assert: TestWriteEffectBeatsReadCarveOut`

### reader-writer-drift
A check whose payload never reaches its subject is green and proves nothing; the reader and the writer of any format change together, and every rule is driven with a mismatched payload requiring the opposite verdict.
Evidence: checker read line 1 while every payload sat on line 2; nine lessons read unbound (corpus L-16 n=8, H-10 ×5).
`assert: TestCheckDrivenWithMismatchedPayload`

### unaudited-self-account
A sentence written after doing PART of a task describes the whole task, and the author never catches it — cite what you COUNTED and name the retained artifact it came from.
Evidence: 29 summary claims falsified across five runs; zero caught by their own author (corpus L-18).
`assert: TestCommitScopeMustBeDeclared`

### settled-ruling-needs-a-home
A gate with no state for a decision already made re-asks it until a counter fires; a human ruling needs a non-forgeable record.
Evidence: an owner ruling held nowhere on disk; the gate re-blocked ten times in 3h19m (corpus L-21).
`assert: TestDisclosedRedHasAHome`

### artifacts-outlive-their-run
Evidence a milestone requires must be provably storable and tracked BEFORE it is produced, not after.
Evidence: a milestone's only capture was untracked and unstorable when the run ended (corpus L-22).
`assert: TestCitedEvidencePathIsRetained`

### registers-over-prose
A thing a human must do belongs in a ranked, greppable register — never in a decision log, a commit message, or prose.
Evidence: a remediation command sat stale inside a BLOCKING row and was a no-op (corpus HA-034).
`assert: TestPendingActionsAreRankedAndPrinted`

## Binding — do not cut

### independent-verdict-writer
Independence is a property of wiring, not of model tier: the judge reads scripted evidence it did not select and writes its own verdict.
Evidence: both orchestrator errors of one run were found only by a self-written verdict (corpus L-04).
`assert: TestClearVerdictIsSelfWritten`

## Open hypotheses seeded with the lessons

| name | hypothesis | kill condition |
|---|---|---|
| `batched-refinements-self-harm` | Batching a retro's refinements into one commit concentrates control-layer risk to the point of self-harm. | A batch lands clean OUTSIDE the supervisor-changeset pattern (`proposals/README.md`). Confirmed ×2, then disconfirmed once under supervision. |
| `refinement-reaches-instance-only` | A refinement addressed at a file + instance is applied to that instance only. | One window where every §7 row's stated invariant was greppable and every instance was reached. Confirmed ×5. |
| `board-cannot-see-orchestrator-error` | The review board's evidence path excludes the artifacts where orchestrator error lives. | A board finds a defect in the run's record rather than in its diff. |
