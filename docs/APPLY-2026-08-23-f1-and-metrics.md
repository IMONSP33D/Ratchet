# APPLY-2026-08-23 — dispatch-store wall (F1) + metrics spine repair

**Status:** APPLIED to the working tree · **NOT VERIFIED ON HOST** until every row of §6 is dated.
**Authored by:** an audit agent (external to the pipeline), at the human owner's explicit request.
**Provenance caution:** this document is the account of the party that made the changes. Every
claim below is stated so it can be falsified by re-running the named command; do that rather than
trusting the summary. In the source pipeline's own measured basis, 12 summary claims in a
changeset of this shape were falsified on review.

---

## 1. What was wrong

**F1 — the dispatch store was agent-writable (HIGH).** `.pipeline/dispatch/<id>.glob` is the
allow-list `scope-guard.sh` checks every write against, and `<id>.baseline` is the evidence the
SubagentStop gates use to attribute work. Both lived in `.pipeline/`, where only
`.pipeline/escalations/**` was denied. A constrained agent could therefore widen its own lane and
forge its own alibi, and every downstream check would then agree with it.

Reproduced before the fix: with `p1.glob = tests/**`, a `Write src/app.py` was blocked
`partition-glob-violation`; after the agent overwrote that same glob with `**`, the identical write
was **allowed**. This falsified the design's own soundness argument — that a path outside the glob
is *provably* not this agent's, because scope-guard refused every write outside it.

**M1 — the metrics spine was disconnected in two independent ways (HIGH, both verified).**

- *Run-token mismatch.* `pipeline-event.sh:198` stamps each event `"run":"r<RUN_START-epoch>"`.
  `run_metrics.py` shelled out to a hooklib function `rt_run_token` **that has never existed
  anywhere in the tree**, silently fell back to `"<milestone>@<epoch>"`, and compared that to
  `r<epoch>` with `==`. Every event from every real run was bucketed as another run's and
  discarded. Measured on a 15-event log: `events_this_run: 0, events_other_run: 15`.
- *Reader/writer vocabulary drift.* `COUNTER_SPECS` named `dispatch`, `gate_block`, `refusal`,
  `verify`, `commit`. The hooks emit `dispatch_baseline`, `stop_gate_block`, `guard_block`,
  `scope_block`, `verify_ran`. **Not one spec type was emitted by any script.** Either bug alone
  renders every counter `null`.

Both were invisible because the fixtures in `run_metrics.py --selftest` and `check_done.py
--selftest` hand-wrote the *reader's* dialect — the selftests agreed with the bug. This is the
harness's own named `reader-writer-drift` failure class, live in its metrics spine.

**M2 — no speed measurement existed.** Only whole-run `work_seconds`/`wall_seconds`. No per-stage
durations, no per-dispatch latency, and no human-wait — the last being the number the work budget
deliberately folds out and therefore the one nobody could see.

## 2. Invariants and all instances

| # | Invariant (the grep) | Instances found | Instances addressed |
|---|---|---|---|
| I1 | A path whose contents decide an agent's own permitted scope must be denied at BOTH the settings layer and the guard layer. `grep -n 'ESCALATIONS_DIR' guard.sh scope-guard.sh settings.template.json escalation-lib.sh` | escalations: 4 layers. dispatch: **0 layers** | all 4 layers now mirrored for `$DISPATCH_DIR` |
| I2 | Every rule id a guard can print must be classified in escalation-lib. `bash guard.sh --list-rules` cross-checked by both selftests | 1 new id | `dispatch-store-write` → `ESC_NEVER_CORE` |
| I3 | Every event type a reader counts must be a type a writer emits. `grep -oE '"[a-z_]+"' COUNTER_SPECS` vs all `_event`/`rt_event` call sites | 14 spec types, **0 emitted** | all specs rebound to the emitted vocabulary; 8 new counters added over types already emitted but never read |
| I4 | A selftest fixture must speak the writer's dialect, not the reader's. | 4 fixtures in `run_metrics.py`, 1 in `check_done.py` | all 5 rewritten to real `ts`/`type`/`run` values |

## 3. Files changed (7)

| File | +/- | Change |
|---|---|---|
| `hooks/guard.sh` | +24/-0 | rule id `dispatch-store-write`; section 3d-bis refusing writes to `$DISPATCH_DIR` by effect; 4 selftest cases. Placed **above** section 7 deliberately — deletions under `$PIPELINE_DIR/` are exempted there, and `rm` reaches `$G_WRITES`. |
| `hooks/scope-guard.sh` | +14/-0 | rule id; refusal inside `s_check_tier2b`; 3 selftest cases. Must live in tier2b — `s_check_partition` returns early for `$PIPELINE_DIR/` and `SCOPE_EXEMPT_PREFIXES` exempts it from the manifest, so a later rule never fires. |
| `hooks/escalation-lib.sh` | +6/-0 | `dispatch-store-write` → `ESC_NEVER_CORE`, with the reasoning comment. No approval can coherently lift a rule whose subject is the approval's own scope. |
| `settings.template.json` | +2/-0 | `Write`/`Edit` deny on `./.pipeline/dispatch/**`. This is the layer that holds when guard.sh's static analysis is defeated by indirection. |
| `hooks/run_metrics.py` | +355/-74 | token repair (`run_token` + `token_set` with legacy acceptance); multi-type specs; `nonzero`/`zero` filter predicates; `__type__` map key; **new `timing` block**; 8 new counters; trend widened to 6 columns; markdown "Where the time went" section; 4 selftest fixtures corrected. |
| `hooks/check_done.py` | +10/-3 | `_mut_metrics` failure fixture rewritten to the emitted vocabulary — its "broken" input had quietly stopped being broken, so check 15's required-opposite-verdict selftest was passing vacuously. |
| `hooks/test_hooks.py` | +266/-0 | 2 new classes, 11 tests, 20 subtests. |

**Not changed:** no doctrine file, no agent definition, no `.context/` file, no emitter. The fix
binds the reader to what the writers already say rather than changing 35 call sites — fewer moving
parts, and the emitted names are more informative than the canonical ones were.

## 4. What is now measured that was not

`timing.stage_seconds` (per-stage, with **`human-wait` as its own stage**), `timing.dispatch_seconds`
(per-dispatch, baseline → gate verdict), `human_wait_seconds` / `human_wait_events` /
`human_wait_open_at_end`, `longest_gap_seconds` + `longest_gap_after`,
`instrumented_span_seconds`, `unparseable_ts`. Plus counters: `approvals_consumed`,
`fast_suite_runs`, `fast_suite_failures`, `gates_skipped_no_command`, `retry_caps_exhausted`,
`repeat_failure_stops`, `budget_halts`, `notifications`, and a `notifications_by_class` map.

Two design decisions worth challenging on review:

1. **Human wait is charged to `human-wait`, never to the stage that was open.** Charging a
   40-minute approval stall to whichever gate last fired reports it as slow tests. On the sample
   run this moved 2,400s off `build-gate`. A misattributed speed number is worse than none.
2. **Human wait is a documented LOWER bound.** A wait still open when the log ends is counted in
   `human_wait_open_at_end` and excluded from the total, because guessing its end would be
   inventing a number.

Resolution is one second (`pipeline-event.sh` writes `%H:%M:%SZ`), so sub-second durations read as
measured-zero. `calendar` was deliberately **not** imported — it is not on the CONTRACT §0.2 stdlib
allow-list, and `time.mktime` would silently apply the machine's local zone and shift every
duration by the UTC offset; epoch conversion uses a naive-UTC subtraction instead.

## 5. Replica verification performed

| Check | Result |
|---|---|
| `bash -n` on all 3 changed shell files | PASS |
| `python3 -c ast.parse` on all 3 changed Python files | PASS |
| `settings.template.json` parses as JSON | PASS (78 deny entries) |
| **F1 exploit replayed end-to-end** | glob widening now BLOCKED via Write **and** via Bash redirect; the pre-fix allow is gone |
| `guard.sh --selftest` | OK — 24 rule ids declared, 24 emitted |
| `scope-guard.sh --selftest` | OK — 11 declared, 11 emitted |
| All 20 embedded selftests | PASS |
| **New tests driven against PRISTINE code** | **22 failed, 6 passed** — every new check fails without the fix; the 6 that pass are the deliberate opposite-verdict controls (sanctioned writer still works; unrelated scratch still writable), which must pass in both states |
| Full suite, pristine baseline | 190 passed, 7 skipped, 132 subtests |
| Full suite, after fix | **201 passed, 7 skipped, 152 subtests, 0 failed** |
| Sanctioned writer | `dispatch-baseline.sh p9 "src/**"` still writes `p9.glob`; guard still allows invoking it |
| Metrics before/after on one 15-event log | before: `events_this_run 0 / other 15`, all counters null. after: all 15 attributed; dispatches 2, guard_refusals 2, verify_runs 2, verify_failures 1 |

## 6. Host verification — a human must run these and date each row

The above was verified in a Linux container. Ratchet's own doctrine says an apply is
`NOT VERIFIED ON HOST` until a person runs it on the real machine. File this table as a
PENDING-HUMAN-ACTIONS row.

| # | Command (from the repo root) | Expect | Date | Result |
|---|---|---|---|---|
| 1 | `bash .claude/hooks/guard.sh --selftest` | `selftest: OK`, 24/24 ids | | |
| 2 | `bash .claude/hooks/scope-guard.sh --selftest` | `selftest: OK`, 11/11 ids | | |
| 3 | `python3 .claude/hooks/test_hooks.py` | 0 failures; count ≥ prior baseline | | |
| 4 | `python3 .claude/hooks/run_metrics.py --selftest && python3 .claude/hooks/check_done.py --selftest` | both PASS | | |
| 5 | Arm a run, emit an event, `run_metrics.py --markdown` | counters non-null; `events_other_run` does not grow | | |
| 6 | **Git-Bash / Windows:** rows 1–4 again | same | | |

Row 6 matters more than the others: `install.ps1` has never been executed on real Windows
(BUILD-NOTES), and these are shell changes.

## 7. Landing

Doctrine requires scoped commits with the suite run between them, stopping at the first red. The
supervisor-changeset exception permits reviewing a batch as one unit; it still lands as separate
commits. Suggested order — each is independently green:

1. `fix(guard): wall the dispatch attribution store (F1)` — guard.sh, scope-guard.sh,
   escalation-lib.sh, settings.template.json, + the `TestDispatchStoreIsNotAgentWritable` class.
2. `fix(metrics): bind the run token to the writer's format` — the `run_token`/`token_set` change
   plus its two tests. **Land alone**: without it, a correctly-named event is still filtered out,
   so step 3 would look like it failed.
3. `fix(metrics): bind counters to the emitted event vocabulary` — COUNTER_SPECS/MAP_SPECS,
   matcher, fixtures in run_metrics.py and check_done.py, + the vocabulary test.
4. `feat(metrics): measure where a run's time goes` — the timing block, trend columns, markdown
   section, + the timing tests.

## 8. What this does NOT fix

Still open from the audit, deliberately out of scope here: F2 heredoc-fed interpreters, F3 awk and
other code-runners, F4 variable/symlink indirection, F5 xargs placeholders (all mitigated today
only by the narrow permission allow-list — they become live holes if `allow[]` is widened); F6 the
forgeable consent record; F7 the sed JSON fallback failing open; F8 budget reset via
`archive` + `start`. Also unaddressed: escalation counters still have no emitter (they live in the
escalation ledger, not the events log) and would be better read from that ledger directly; and
`retro.md:40` still promises a "time per stage" field — that promise is now *true* in
`timing.stage_seconds`, but the line should be updated to name the real key.
