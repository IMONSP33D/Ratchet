# Plan — `agent-development-export.sh` / `agent-development-export.ps1`

**Status:** PLAN (not yet implemented) · **Date:** 2026-08-23 · **Companion to:**
`docs/audit-2026-08-23-autonomous-pipeline.md` §5

## Purpose

One command that gathers every signal the learning loop produces in the current project into a
single, versioned, redacted, diffable bundle — so the next iteration of Ratchet (or a fleet view
across projects, or an offline optimization pass) can be improved from *evidence* instead of
memory. Today that evidence is scattered across `.agent-development/`, `.pipeline/` (and its
archive), the escalation ledger, and git history, and part of it (stage durations, human-wait,
closure status) exists only implicitly. The exporter computes the implicit parts and ships the
whole picture.

## Design principles

The tool is **read-only against everything it collects** — it writes only its own output
directory. It is **stdlib-only** (bash 4 + jq + the already-required Python 3.8; PowerShell 5.1+
on Windows), matching the harness's dependency doctrine. It **fails loud and partial**: a missing
or unparsable source never aborts the export and never silently disappears — it becomes a named
row in the bundle's `gaps[]` with a reason, honoring the harness's null-vs-zero rule ("null =
not instrumented, 0 = measured zero"). It is **deterministic**: two runs over unchanged state
produce byte-identical bundles (stable key order, no embedded timestamps outside one `meta`
field), so exports can be diffed and committed. It is **redacted by default**: no secrets
directory, no `.env` values, no webhook URLs, no absolute home paths; `--include-raw` exists but
prints a warning naming what it un-redacts.

Ownership: the script lives in `.claude/hooks/` (control layer, Tier 2b, agents read-only), is
listed in settings `allow[]` as agent-invocable (same class as `run_metrics.py` and
`gc-prune.sh`), and emits one `export_run` event via `pipeline-event.sh` so exports are visible in
the mechanical record. Output goes to `.agent-development/exports/` — inside the never-pruned
tree, so exports are corpus.

## Invocation

```
.claude/hooks/agent-development-export.sh [--out DIR] [--runs N|all] [--redact|--include-raw]
                                          [--format json|json+md] [--since RUN|DATE]
                                          [--verify-closures] [--quiet]
.\.claude\hooks\agent-development-export.ps1 [-Out DIR] [-Runs N] [-Redact] [-Format ...]
                                          [-Since ...] [-VerifyClosures] [-Quiet]
```

Defaults: all runs, redacted, `json+md`, closures verified. Exit 0 on complete export, 3 on
partial (gaps present), 1 on unable-to-start (not a Ratchet tree). Never exit-2 — this is not a
gate.

## What it gathers (the eight sections of `export-bundle.json`)

**1. `meta`** — bundle schema version, Ratchet `VERSION`, export timestamp (the one volatile
field), project name, stack pack + resolved command bindings (the 13 variables, values redacted
to command *names*), base branch, git HEAD, whether branch protection was ever confirmed
(pending-action state), OS/shell fingerprint.

**2. `runs[]`** — one object per run, joined from three sources keyed by run number: the metrics
sidecar (`​.agent-development/metrics/NNN-*.json` — all counters, maps, work/wall seconds,
end-state git stats, contradictions), the run doc frontmatter (`runs/NNN-*.md` — milestone,
outcome token), and the INDEX.md row. Missing sidecar → the run appears with `metrics: null` and
a gap row (the loop's known failure: "why this sidecar went unwritten for the harness's entire
first window").

**3. `derived_timing[]`** — computed here because nothing else computes it (the audit's headline
metrics gap). A pure reader over `run-events.jsonl` + `.pipeline/archive/`: per-run stage
durations (deltas between `run_start`, `dispatch_baseline`, `checkpoint_evidence`,
`gate` events, `run_archive`), per-gate retry counts and latencies, and **human-wait** — the gap
between each `notification` event and the next event of any type, summed per run and per cause
(Ship Prompt vs escalation vs decision card). These are the numbers the speed workstream needs
and the current trend view lacks.

**4. `enforcement`** — refusals by rule id (from events + `unclassified-rules.log` if present),
escalations from `.pipeline/escalations/ledger.jsonl` and archives: requested/approved/expired/
rejected counts, time-to-approval distribution, and the expired-unanswered list (the cost of the
TTY-bound TTL, currently invisible). Gate blocks by gate with repeat-failure stops. This section
is what tells the next iteration *which walls fire in practice and which never do*.

**5. `learning_state`** — ACTIVE-LESSONS parsed to structured rows (name, statement, recurrence,
assert, seeded-vs-local); PENDING-HUMAN-ACTIONS rows with status and age-in-days (BLOCKING rows
highlighted); consolidation coverage (which 5-run windows have a consolidated doc — mirrors
check 19); refinement rows harvested from every run doc §7 (name, target file, invariant,
instances, expected effect, risk).

**6. `closure_verification[]`** — only with `--verify-closures` (default on): for every
refinement/lesson that claims to be applied or resolved, (a) grep its stated invariant to confirm
the change is present at the stated target and enumerate any instances the fix missed, and
(b) confirm its named `assert:` test exists in `test_hooks.py` — running the suite itself is
optional (`--run-asserts`) since the export must stay cheap. Output per row:
`applied-and-held | applied-but-instances-remain | not-found | unverifiable(reason)`. This is the
loop's biggest silent-failure fix: proposals that were never applied, and closures that were
silently reverted, become visible in every export.

**7. `context_budget`** — line/word/approx-token counts of every always-loaded and per-dispatch
instruction file (doctrine, agent seats, ACTIVE-LESSONS, context-live at export time), so
context growth is trended across exports and across Ratchet versions instead of re-measured by
hand at every audit.

**8. `gaps[]`** — every source that was missing, unparsable, or skipped, with reason. An empty
`gaps[]` is the definition of a complete export.

## Human-readable summary (`export-summary.md`)

Written next to the bundle when `--format json+md`: a one-page digest — runs and outcomes table,
the five slowest stages, human-wait total, top refusal rules, MUST-FIX lessons, closure failures,
and the gaps list. This is what a person (or the retro of a *different* project) reads first.

## How the next iteration consumes it

The bundle is the input contract for three consumers: (a) **the next Ratchet release** — fleet
diffs of `enforcement` and `derived_timing` across projects show which rules misfire and where
wall-clock actually goes before any doctrine is edited; (b) **consolidation** — the retro/
consolidation seats may read the latest export instead of re-deriving counters, and
`closure_verification` gives them the evidence rows the templates demand; (c) **offline
optimization** — `runs[]` + `derived_timing` + refinement variants are exactly the trace-and-
outcome pairs a GEPA-style prompt-evolution pass needs. The schema version in `meta` is the
compatibility gate: consumers refuse a bundle whose major version they don't know.

## Implementation notes

Shell does orchestration and file discovery; all JSON assembly is one embedded-or-adjacent
Python (`export_lib.py`) invoked via the existing `rt_pick_py` probe, because the harness already
trusts Python for JSON and forbids guessing with sed. The PS1 variant reuses `export_lib.py`
verbatim (PowerShell gathers paths, Python builds the bundle) so the two scripts cannot drift in
the part that matters — one writer, two launchers, honoring the reader-writer-together rule.
Estimated size: ~200 lines per launcher + ~400 lines of Python. Tests (in `test_hooks.py`
style): a fixture tree with two fake runs → golden bundle; each gap class driven with a
mismatched payload (missing sidecar, corrupt JSONL line, unreadable ledger) and required to
produce the *opposite* verdict (gap row, exit 3) — per loop rule 3, a check that can only PASS
is not a check.

## Landing plan (supervisor-changeset compatible)

1. `export_lib.py` + fixtures + tests (no wiring) — pure addition, one commit.
2. `agent-development-export.sh` launcher + settings `allow[]` entry — one commit, suite between.
3. `agent-development-export.ps1` launcher — one commit (flagged: PS1 parity is untested on real
   Windows, like `install.ps1`; file the host-verification row in PENDING-HUMAN-ACTIONS).
4. Doctrine touch: one paragraph in `.agent-development/README.md` and a `retro.md` §2 pointer
   ("read the latest export if present") — via supervisor changeset, since it edits Tier 2b.
5. Optional follow-up: `gc-prune.sh archive` calls the exporter automatically at gate closure so
   every completed run leaves a bundle behind.
