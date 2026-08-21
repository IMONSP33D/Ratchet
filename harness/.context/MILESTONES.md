# MILESTONES.md — Build Order & Win Conditions: {{PROJECT_NAME}}

<!-- ============================================================================
     THIS FILE IS A STUB. A HUMAN MUST FILL IT IN BEFORE THE FIRST RUN.
     Two worked milestones are provided below. Edit them; do not invent from scratch.
     Read .context/CONVENTIONS.md §3-4 before writing a WIN row.
     ============================================================================ -->

Version 0.1 · <!-- YYYY-MM-DD --> · Companions: `SPEC.md` (the contract), `CLAUDE.md` (how to work),
`PIPELINE.md` (stage mechanics), `CONVENTIONS.md` (structural conventions).

**This file is the sole source of milestone numbering.** Where any other document uses an M-number, it
means the milestone defined here. Human-owned, Tier 2b; agents MUST NOT edit it.

---

## How to read a WIN row

Every WIN row is **script-decidable**: it has a verify command that exits 0 or non-zero, and a human
never adjudicates it. A row without a verify command is a setup defect — raise it, never judge it
(`CLAUDE.md` law 2).

| Field | Meaning |
|---|---|
| **WIN ID** | `WIN-M<n>-<nn>`. A **coordinate**, not a label: positional, never renumbered, never reused. Referenced in test names and commits. |
| **Name** | Kebab-case, 2–5 words, states what the row proves. This is what humans cite, and it is unique across the project's findings, lessons, decisions and pending actions. |
| **Requirements** | The `REQ-`/`SEC-`/`TEST-`/`INV-`/`AV-` ids this row proves. At least one, or `—` for a structural row. |
| **Verify** | The command. Exit 0 = pass. A wrapper target (`make win-m<n>-<nn>`) unless the invocation is short, stable and self-explanatory. |
| **Evidence** | Where the raw output lands, under `docs/evidence/M<n>/`. |

Row order in the table is the five fields above, in that order:

```
| WIN-M<n>-<nn> | <name> | <requirement ids> | <verify command> | <evidence path> |
```

**Write the verify command before you write the condition.** A condition you cannot write a command
for is a condition you do not yet understand, and it will reach a run as an unadjudicable row.

**State conditions so they can fail**, with the number in them. Where the honest answer may be
negative, say so in the row: a measurement row is satisfied by reporting the measurement, including
"inconclusive". A row that can only be satisfied by a favourable result is a target, not a test, and
it will be met by tuning.

Evidence for every row lands in `docs/evidence/M<n>/` and is cited in the ship report. **Run scope is
ONE milestone**, or a declared WIN subset of one.

---

## Milestone skeleton

Every milestone block has exactly these parts:

```markdown
# M<n> — <title>

**Goal.** One sentence: what is true after this milestone that was not true before.
**Entry.** What must already hold. An unmet entry criterion stops the run before Stage 1.
**Run type.** standard | standard + soak | human-executed

| WIN | Name | Requirements | Verify | Evidence |
|---|---|---|---|---|
| ... |

**Exit gate.** What closes M<n>. Normally "all rows green; PR merged".
**Halt triggers.** Conditions that stop the run outright rather than failing a row. Omit if none.
```

**Run types.**

| Type | Meaning |
|---|---|
| `standard` | One agent run, Stages 0–6, ending in a Ship Prompt. |
| `standard + soak` | A standard run that launches a long unattended validation run at its close. The soak's WIN rows are evaluated by a **separate later run** (`PIPELINE.md`). |
| `human-executed` | A human performs the milestone. Agents may build tooling and analyse results; they may not perform the gated act. Tier 2b. |

---

## Milestone map

<!-- One row per milestone. Fill this in; it is the index every other document reads. -->

| M | Name | Run type | Gate character |
|---|---|---|---|
| M0 | Scaffold & configuration spine | standard | ordinary |
| M1 | <!-- first real capability --> | standard | ordinary · <!-- AV ids --> |
| <!-- M2 --> | <!-- --> | <!-- --> | <!-- --> |

Dependencies: <!-- linear unless stated; draw the graph if a soak runs in parallel with the next milestone -->

<!-- If any milestone contains an unattended validation window, state the minimum wall clock to the
     final milestone here and say plainly that no amount of compute compresses it. That number is
     the single most useful line in this file for planning. -->

---

# M0 — Scaffold & configuration spine

<!-- WORKED EXAMPLE. Edit the rows to match your SPEC; keep the shape. M0 exists so that every
     later milestone has a place to put its code and its proof. Its rows are almost entirely
     structural, which makes them the easiest rows in the project to write as real commands. -->

**Goal.** A repository where every later milestone has a place to put its code and its proof, and
where `{{VERIFY_CMD}}` runs green on an empty-but-valid tree.
**Entry.** Empty or near-empty repository; the Ratchet control layer installed and `test_hooks.py`
passing.
**Run type.** Standard.

| WIN | Name | Requirements | Verify | Evidence |
|---|---|---|---|---|
| WIN-M0-01 | canonical-tree-exists | §4 | `make win-m0-01` | `docs/evidence/M0/canonical-tree-exists.txt` |
| WIN-M0-02 | verify-runs-green-empty | TEST-03 TEST-06 | `{{VERIFY_CMD}}` | `docs/evidence/M0/verify-runs-green-empty.txt` |
| WIN-M0-03 | config-rejects-out-of-domain | REQ-CFG-01 | `make win-m0-03` | `docs/evidence/M0/config-rejects-out-of-domain.txt` |
| WIN-M0-04 | conservative-defaults-resolve | REQ-CFG-02 AV-01 | `make win-m0-04` | `docs/evidence/M0/conservative-defaults-resolve.txt` |
| WIN-M0-05 | no-literal-for-config-value | REQ-CFG-02 | `make win-m0-05` | `docs/evidence/M0/no-literal-for-config-value.txt` |
| WIN-M0-06 | no-secret-path-tracked | SEC-01 SEC-10 | `make win-m0-06` | `docs/evidence/M0/no-secret-path-tracked.txt` |
| WIN-M0-07 | ci-blocks-on-failure | TEST-06 | `make win-m0-07` | `docs/evidence/M0/ci-blocks-on-failure.txt` |

<!-- Notes on the example rows, worth copying as habits:
     - WIN-M0-01 diffs the actual tree against the SPEC §4 manifest. A tree assertion is the
       cheapest structural row there is and it stops drift for the whole project.
     - WIN-M0-02 asserts the gate itself works before anything depends on it.
     - WIN-M0-05 is a grep-style row: "this literal appears nowhere in the source tree".
       Grep rows are excellent WIN rows precisely because they cannot be argued with.
     - WIN-M0-07 verifies the CI config blocks, not merely that it exists. "Exists" rows are the
       most common way a milestone passes without proving anything. -->

**Exit gate.** All rows green; PR merged.

---

# M1 — <!-- first real capability -->

<!-- WORKED EXAMPLE. M1 is the first milestone that touches the outside world, which is why it
     carries the AV rows. Note the two shapes of row here: deterministic rows that run in the
     ordinary suite against recorded fixtures, and explicitly-marked capture rows that reach a
     live source once and record what they found. -->

**Goal.** The system can perform its primary external interaction as an authenticated identity, under
its real limits, with every volatile fact in scope measured rather than assumed.
**Entry.** M0 closed. Credentials for the non-production environment issued — if not, the milestone is
`blocked_external` and the run reports the human action needed.
**Run type.** Standard.

| WIN | Name | Requirements | Verify | Evidence |
|---|---|---|---|---|
| WIN-M1-01 | sign-message-golden-reproduces | REQ-AUTH-01 | `pytest -k REQ_AUTH_01` | `docs/evidence/M1/sign-message-golden-reproduces.txt` |
| WIN-M1-02 | sign-verify-roundtrip-passes | REQ-AUTH-01 | `pytest -k signing_roundtrip` | `docs/evidence/M1/sign-verify-roundtrip-passes.txt` |
| WIN-M1-03 | authenticated-call-succeeds | REQ-AUTH-02 AV-02 | `make win-m1-03` | `docs/evidence/M1/authenticated-call-succeeds.txt` |
| WIN-M1-04 | startup-refuses-bad-key-mode | REQ-AUTH-03 SEC-02 | `pytest -k key_permissions` | `docs/evidence/M1/startup-refuses-bad-key-mode.txt` |
| WIN-M1-05 | backoff-bounded-and-jittered | REQ-INGEST-02 AV-01 | `pytest -k REQ_INGEST_02` | `docs/evidence/M1/backoff-bounded-and-jittered.txt` |
| WIN-M1-06 | retry-is-resubmit-safe | REQ-INGEST-03 | `pytest -k idempotency` | `docs/evidence/M1/retry-is-resubmit-safe.txt` |
| WIN-M1-07 | rate-limit-measured-not-assumed | AV-01 | `make win-m1-07` | `docs/evidence/M1/probes/rate-limit-measured-not-assumed.txt` |
| WIN-M1-08 | endpoint-shape-verified | AV-02 | `make win-m1-08` | `docs/evidence/M1/probes/endpoint-shape-verified.txt` |
| WIN-M1-09 | redaction-masks-credentials | SEC-03 | `pytest -k redaction` | `docs/evidence/M1/redaction-masks-credentials.txt` |

<!-- Notes:
     - WIN-M1-02 tests a round-trip with a throwaway keypair rather than pinning a fixed
       signature. Pinning a signature from a randomised scheme tests the fixture, not the code.
     - WIN-M1-07 and -08 are AV capture rows. Their evidence goes under probes/ as raw,
       unrewritten output. The measured values then land in config defaults and a DECISIONS
       entry — never as code literals.
     - WIN-M1-04 is a refusal row: it proves the system REFUSES, not that a check exists.
       Prefer refusal rows to existence rows everywhere. -->

**Exit gate.** All rows green; PR merged.
**Halt triggers.** <!-- A measured AV value outside the range the architecture survives → stop the
build and raise. Production credentials found in the environment → Hard Stop. -->

---

## Appendix — open-items ledger

<!-- Mirrors SPEC.md §14. One list, not two: each AV item moves open -> measured -> configured,
     with the milestone that resolved it, the evidence path, and a re-check cadence for items
     that can regress. -->

| AV | Item | Resolves at | State | Evidence |
|---|---|---|---|---|
| <!-- AV-01 --> | <!-- upstream rate limit --> | <!-- M1 --> | <!-- open --> | <!-- --> |
| <!-- AV-02 --> | <!-- endpoint shape & auth --> | <!-- M1 --> | <!-- open --> | <!-- --> |
| — | <!-- the project's central unproven assumption --> | <!-- the hard-gate milestone --> | open | — |

<!-- The last row is worth keeping even if you have no AV items. Most projects have exactly one
     assumption whose failure ends the project. Name it, name the milestone that tests it, and
     let that milestone be allowed to return NO-GO. A NO-GO on the merits is a successful run. -->
