# CONVENTIONS.md — Structural Conventions · {{PROJECT_NAME}} · Ratchet harness

**What this is.** The normative structural conventions of a Ratchet project: how requirements are
identified, what makes a verify command valid, how WIN rows are written, how volatile external facts
are tracked, where evidence lives, how tests are named, how commits are shaped, and the exact format
of every artifact a parser reads.

**Who owns it.** Human-owned, Tier 2b. Agents MUST NOT edit it. It is the reference `SPEC.md`,
`MILESTONES.md` and `DECISIONS.md` are written *against*; it does not itself contain project content.

**Why it exists.** In the corpus this harness was distilled from, every convention below existed only
by example — inferable from a well-written SPEC, invisible to anyone starting a new one. A convention
that lives only in an example is re-invented by every project, differently. RFC 2119 keywords apply.

---

## 1. The four-directory ownership partition — the harness's core idea

Ratchet's central claim is that autonomy is safe exactly when **ownership is a directory boundary, not
a promise**. Four trees, four owners, enforced by `scope-guard.sh` and `guard.sh` rather than by
intent:

| Tree | Owner | Agent access | Lifetime |
|---|---|---|---|
| `.claude/` | The control layer | **Unwritable.** The control set within it is never-escalatable; the rest is refused by default and changeable only by an approved byte-exact write. | Permanent |
| `.context/` | The human | **Read-only, Tier 2b.** `SPEC.md`, `MILESTONES.md`, `PIPELINE.md`, `CONVENTIONS.md`, `CLAUDE.md`. Agents propose changes through `DECISIONS.md` and the retro. | Permanent |
| `.pipeline/` | The agents | Read/write scratch. Pruned by `gc-prune.sh`; mostly gitignored. | **Run-scoped** — archived at gate closure |
| `.agent-development/` | The learning loop | Append-only in spirit; scope-exempt; **never pruned**. | Permanent |

Everything else in the repo — source, tests, docs, evidence — is ordinary work product, gated by the
run's manifest.

Two consequences worth stating explicitly:

- **A rule the agent could edit is not a rule.** This is why the control set is never-escalatable even
  under an approval: the files that decide what an approval means cannot be changed by one.
- **A run-scoped tree must be cleared at gate closure.** A manifest from a closed milestone gating an
  unrelated session is a real failure mode, not a hypothetical.

---

## 2. Requirement-ID taxonomy

Every requirement has a stable id. Tests, commits, WIN rows and DECISIONS entries cite these ids, and
those citations are what the proof map and the mission trace follow.

### 2.1 The five namespaces

| Prefix | Means | Form | Example |
|---|---|---|---|
| `REQ-` | A functional requirement — the system MUST do this | `REQ-<MODULE>-<nn>` | `REQ-AUTH-01` |
| `SEC-` | A security requirement — a control, a boundary, a refusal | `SEC-<nn>` | `SEC-04` |
| `TEST-` | A testing requirement — how the suite itself must behave | `TEST-<nn>`, properties `TEST-P-<nn>` | `TEST-03`, `TEST-P-01` |
| `INV-` | An invariant — a relation that must hold at all times, usually property-tested | `INV-<DOMAIN>-<nn>` | `INV-LEDGER-01` |
| `AV-` | An **assumption to verify** — a volatile external fact. See §5 | `AV-<nn>` | `AV-01` |

`REQ-` is namespaced by module because functional requirements grow per module and a flat sequence
becomes unreadable. `SEC-` and `TEST-` are flat because they are cross-cutting and few. `INV-` is
namespaced by the domain the invariant governs.

### 2.2 Rules that bind all five

1. **Ids are permanent and never reused.** A requirement that is replaced gets a NEW id; the old id
   is marked SUPERSEDED in place and keeps resolving forever. A citation that resolves to nothing
   still reads as though it resolves — that is the failure mode.
2. **Numbering is per-namespace and monotonic.** Never renumber to close a gap.
3. **Every id is stated so it can fail.** "The system handles errors gracefully" is not a
   requirement; "an unhandled exception in the main loop MUST be logged with a stack trace, increment
   the breaker, and not terminate the process" is.
4. **A requirement that no test can cite is a design note, not a requirement.** Move it to prose.

### 2.3 Extending the taxonomy

Adding a namespace is a change to the governing corpus: it goes through a `DECISIONS.md` entry and a
human edit to `SPEC.md`, never through an agent. When you add one, declare in `SPEC.md` §2:

- the prefix and its exact form;
- what class of statement belongs in it and what does not;
- whether it is flat or namespaced, and by what;
- what artefact proves one (a test? a probe? a config default? a human sign-off?).

The last item is the one people forget, and it is the one that decides whether a WIN row can cite it.

---

## 3. Verify commands

A WIN row's verify command is the mechanism by which milestones stop being a matter of opinion.

### 3.1 What makes a verify command VALID

All five MUST hold:

| Property | Meaning | Fails if |
|---|---|---|
| **Script-decidable** | It is a command, not a description | "review the logs and confirm" |
| **Exit 0 = pass** | Exactly. Non-zero = fail. Nothing else is consulted | It prints PASS but exits 0 unconditionally |
| **Deterministic** | Same commit, same inputs, same verdict | It samples live data with no recorded fixture |
| **Network-free** | Unless the row explicitly exists to prove an external interaction, and is marked as such | A unit-tier row that silently reaches the network |
| **Non-interactive** | No prompt, no TTY requirement, no pager | It opens `less`, or waits for a keypress |

A command that only ever emits PASS is not a check. **If you write a verify command, be able to state
the input that makes it fail.**

### 3.2 The wrapper-target convention

Every WIN row's verify command SHOULD be a **named target in the project's task runner**, wrapping
whatever the real command is:

```
make win-m1-03          # wraps: pytest -k "REQ_AUTH_01 or REQ_AUTH_02" --no-header
```

Naming pattern: `win-m<n>-<nn>`, lowercase, matching the WIN id.

Three reasons this is a convention and not a preference:

1. **The row survives a tooling change.** The wrapper moves; the milestone document does not, and
   `MILESTONES.md` is Tier 2b and expensive to change.
2. **A human can run one row.** Reproducing a single WIN result should take one command that they can
   read off the table.
3. **The command is testable in isolation.** A wrapper target can be invoked by `check_done.py` and by
   the evidence capture without re-deriving what the row meant.

A row whose verify command is a bare inline invocation is acceptable when the invocation is short,
stable and self-explanatory (`pytest -k redaction`). A row whose command is a multi-clause shell
pipeline MUST be wrapped.

### 3.3 Rows that need a fixture, not a network

When a row proves behaviour against an external interface, the row that runs in the ordinary suite
verifies against a **recorded, scrubbed fixture**; a separate, explicitly-marked row performs the live
capture. Never model an external interface from a guess — capture a real response, scrub it, and model
from that.

---

## 4. WIN rows

### 4.1 The field spec

A WIN row is a pipe-table row in `MILESTONES.md`, with exactly these five fields in this order:

```
| WIN-M<n>-<nn> | <name> | <requirement ids> | <verify command> | <evidence path> |
```

| Field | Rules |
|---|---|
| **id** | `WIN-M<n>-<nn>`, zero-padded to two digits. **Positional — it is a coordinate, not a label.** Never renumbered, never reused. |
| **name** | Kebab-case, 2–5 words, per the naming doctrine. States what the row proves: `sign-message-golden-reproduces`, not `auth-test-1`. This is what humans cite. |
| **requirement ids** | Space-separated `REQ-`/`SEC-`/`TEST-`/`INV-`/`AV-` ids this row proves. At least one, or an explicit `—` for rows that prove a structural property with no requirement id. |
| **verify command** | Per §3. **Mandatory.** |
| **evidence path** | Under `docs/evidence/M<n>/`. Where the raw output of the verify command lands. |

### 4.2 The setup-defect rule

**A WIN row with no verify command is a setup defect.** It is raised to the human, never adjudicated
by judgment, and never satisfied by an argument that the condition is obviously met. This is law 2 and
it has no exceptions:

- The orchestrator cannot decide the row passed.
- The `clear-reviewer` cannot CLEAR a checkpoint that rests on it.
- A NO-GO cannot be earned on a row that never ran.

The remedy is a human edit to `MILESTONES.md` supplying a command — which is exactly why milestone
authoring (§ MILESTONES.md's own guidance) insists on writing the command before writing the
condition.

### 4.3 Conditions are stated so they can fail

Write the condition as the thing that would be false if the system were wrong, with the number in it.
"Coverage is good" is not a WIN row. "Critical-file coverage ≥ 95% on the declared critical set" is.

Where a row's honest answer may be negative, say so in the row: a measurement row is satisfied by
reporting the measurement, including "inconclusive". A row that can only be satisfied by a favourable
result is a target, not a test, and it will be met by tuning.

---

## 5. The AV register — volatile facts get verified, not assumed

### 5.1 What belongs in it

An `AV-` item is a fact about the world **outside the repository** that the design depends on and that
can change without notice: an external API's shape, a rate limit, a quota, a model id, a third-party
default, a regulatory date. Anything you would otherwise write as "as of today, X is Y".

It does NOT include: internal design choices (those are `DECISIONS.md`), things the suite can prove
(those are `REQ-`), or preferences.

The test is: **if this fact changed silently tomorrow, would the system be wrong and the tests still
green?** If yes, it is an AV item.

### 5.2 The lifecycle — `open` → `measured` → `configured`

| State | Meaning | Where it lives |
|---|---|---|
| **open** | Declared in the SPEC's AV register with the source it must be verified against, and a *conservative* default in config. The design must survive the unfavourable branch. | `SPEC.md` AV register |
| **measured** | A run has verified it against a live source and captured raw evidence under `docs/evidence/M<n>/probes/`. The measurement is recorded in a `DECISIONS.md` entry citing the AV id. | Evidence + DECISIONS |
| **configured** | The measured value is written into the project's config defaults, and the AV row records the milestone that resolved it and the evidence path. | Config + AV register |

**An AV outcome updates config defaults and `DECISIONS.md` — never code literals.** A measured value
hard-coded into logic has left the register and cannot be re-measured.

### 5.3 Rules

1. **Verification of each AV item is a WIN row** in the milestone where it resolves. An AV item nobody
   is required to verify is a comment.
2. **While an item is open, carry both branches.** If the unfavourable branch would change a result,
   the run reports both, labelled. Reporting one series while the assumption is unresolved is a defect.
3. **An AV verification that contradicts a frozen contract** is the orchestrator's to decide — a
   `DECISIONS.md` entry, and a Decision Card only if it moves a load-bearing constant.
4. **Ground truth beats documentation.** Where an AV item can be read off a real artifact (a response,
   a record, a receipt), that artifact is the source and any document is secondary — including this
   one.
5. **Some items never close.** An item that can regress (a third-party default, a program with an end
   date) is re-checked at a stated cadence, and the register says so.

---

## 6. Goldens become unit tests

A **golden** is a hand-derived expected value: computed by a human, by hand or by an independent
method, and written into the SPEC.

| Rule | Detail |
|---|---|
| Goldens live in the SPEC | In the formula section that defines them, with the derivation shown. |
| Every golden becomes a named test | With the value as a **literal in the test**, not computed at test time. |
| The derivation goes in the test docstring | So the next reader can check the number without leaving the file. |
| **A golden is never generated by the implementation** | A value produced by the code under test proves only that the code is consistent with itself. This is the single most common way a golden suite becomes decorative. |
| Changing a golden requires a DECISIONS entry | In the same commit, citing what made the previous value wrong. |
| Properties complement goldens | Goldens pin specific points; property tests (`TEST-P-`) pin the shape between them. Math-heavy code needs both. |

---

## 7. Evidence layout

```
docs/evidence/
  M<n>/
    proof-map.md            # GENERATED by proof_map.py — never hand-edited
    <win-name>.txt          # raw output of a WIN row's verify command
    probes/
      <probe-name>.txt      # verbatim command output, unedited
    postmortem.md           # present only on a NO-GO or a halted validation run
```

Rules:

1. **Raw output, unrewritten.** Paste the command's actual output. Output nobody rewrote is better
   evidence than a description of it, and a description is a second telling that can drift.
2. **`proof-map.md` is generated at HEAD**, by `python .claude/hooks/proof_map.py --milestone M<n>`.
   Never hand-maintain it. The contract freezes the WIN → *selector* mapping and the test names are
   derived, which removes the "map narrower than its own selector" defect class by construction —
   there is no second copy of the answer to disagree.
3. **Every WIN row must collect at least one test** in the proof map. Zero is either a missing test or
   a selector defect; both are fixed, neither is adjudicated.
4. **Evidence is durable.** `docs/evidence/` is tracked, is never pruned by `gc-prune.sh`, and is
   cited by path from the ship report and from findings rationale — never pasted into them.

---

## 8. Test naming and WIN-load-bearing selectors

### 8.1 Tests carry requirement ids

Every test that proves a requirement carries that requirement's id **in its name**, with separators
normalised to the language's identifier rules:

```
test_bucket_total_rounds_up_REQ_AGG_02
test_key_permissions_refused_SEC_02
test_totals_sum_across_buckets_INV_LEDGER_02
```

The id in the name is what the proof map, the mission trace and `check_done.py` follow. A requirement
whose id appears in no test name is unproven regardless of how well it is implemented.

Docstrings carry the id too, in prose, along with the derivation for goldens.

### 8.2 Contract-declared selectors are load-bearing

The `architect` freezes, per WIN row, the **selector substring** the row's verify command uses (for
example `REQ_AGG`, or `signing_roundtrip`). That substring is a contract:

- A test that means to serve a WIN row MUST contain the row's selector substring in its name.
- Renaming a test so it no longer matches the selector **silently removes it from the row's proof**,
  and the suite stays green while the row stops being proven.
- Therefore: **a rename that changes a selector match is a contract change**, needs a DECISIONS entry,
  and is a `checkpoint-scribe` audit item — exactly like modifying a test.

`proof_map.py` is what makes this visible: it lists, per WIN row, the tests the selector actually
collects at HEAD. A row that loses a test between runs shows up as a shrinking collection.

---

## 9. Commits

**Conventional Commits**, one per green TDD cycle.

```
<type>(<scope>): <subject>          # types: feat fix test refactor docs chore build ci perf

Body: what changed and why, referencing requirement ids.
Footer: DEC-nnn · <name> when a decision was recorded in the same commit.
```

| Rule | Detail |
|---|---|
| **One green cycle = one commit** | Red → green → refactor → commit. Not "one feature", not "one session". |
| **Reference requirement ids** | In the subject or the body. This is how the mission trace reads history. |
| **A decision commits with its subject** | A DECISIONS entry lands in the *same commit* as the change it authorises, never after. |
| **Size is a signal** | A diff exceeding `COMMIT_SCOPE_LINES` (400) means cycles were batched. Split it. |
| **Never `--no-verify`** | The pre-commit surface is part of the gate, not an obstacle to it. |
| **Test and implementation commit separately** | The test-writer's red commit and the developer's green commit are different commits by different seats. A single commit containing both is indistinguishable from test-after. |

Branches: `agent/<task>`, `<task>` kebab-case per the naming doctrine. Work reaches `{{BASE_BRANCH}}`
only through the PR.

---

## Appendix — Artifact formats (frozen; parsers read these)

Every format below is read by a script. Changing one breaks its reader. They are restated here in full
so a human can write one correctly without reading the parser.

### A1. WIN row — `MILESTONES.md`

```
| WIN-M<n>-<nn> | <name> | <requirement ids> | <verify command> | <evidence path> |
```

Verify command must be script-decidable (exit 0 = pass). A row with no verify command is a setup
defect — raised, never adjudicated. See §3, §4.

### A2. Proof map

Input: the contracts table, with frozen column names **`win`** and **`selector`**.
Output: `docs/evidence/M<n>/proof-map.md`, generated. Every WIN row must collect ≥1 test.

### A3. DECISIONS entry — `DECISIONS.md` (hot) and `.context/archive/decisions/` (cold)

```
## DEC-nnn · <name>
**Date.** YYYY-MM-DD · **Status.** ACTIVE | SUPERSEDED by DEC-mmm
**Decision.** <=120 words, stated so it can be checked.
**Default/config.** <key = value>                (omit if none)
**Supersedes.** DEC-nnn · <name>                 (omit if none)
**Affected.** <requirement ids>
**Simulated.** Simulated against <n> frozen rows; <k> changed meaning: <list>
**Archive.** .context/archive/decisions/DEC-nnn-full.md
```

Hot file: soft cap 250 lines, hard cap 300. **Appending a decision must never be the failing action**
— over the hard cap the checker emits `ROLLOVER-REQUIRED` and the append is still permitted.

### A4. Findings ledger — `.pipeline/findings.md`

Pipe table, header frozen:

```
| name | source | severity as filed | file:line | finding | disposition | rationale | DEC |
```

- **name** — naming doctrine, unique across findings, lessons, pending actions and decisions.
- **severity as filed** — as the reviewing agent filed it. **Never edited.** Disposition is a separate
  column.
- **disposition** — one of `FIXED` `ACCEPTED` `DEFERRED` `WAIVED`.
- **rationale** — `FIXED` ≤ 40 words; `ACCEPTED`/`DEFERRED`/`WAIVED` ≤ 80 words **and a DEC id is
  mandatory**.
- **No probe transcripts in cells.** Cite an evidence path.

### A5. Board raw outputs

`.pipeline/reviewer-findings.md` and `.pipeline/security-findings.md`. One numbered finding per item,
`1.` at line start. The count is reconciled against the ledger by `check_done.py`.

### A6. Manifest and amendments

- `.pipeline/plan-files.txt` — one repo-relative path per line.
- `.pipeline/manifest-amendments.txt` — `<path> <DEC-id> [note]`, one per line. **One shared parser**
  serves the Stop gate and `check_done.py`, so a line that satisfies one satisfies the other.

### A7. Checkpoints — `.pipeline/checkpoints/`

| File | Written by | Constraints |
|---|---|---|
| `<n>-<stage>-jump.md` | `checkpoint-scribe` | 7 sections, ≤500 words |
| `<n>-<stage>-evidence.txt` | `checkpoint-evidence.sh` | **Script-written only.** Never edited, never curated |
| `<n>-<stage>-clear.md` | `clear-reviewer` itself | ≤200 words; names its spot-check and what it found; final line alone: `CLEAR` / `BLOCK: <reasons>` / `ESCALATE: <reason>` |
| `<n>-<stage>-fast.md` | The orchestrator | The FAST checklist, each item answered, one verdict |

### A8. Recap — `.pipeline/recap.md`

Exactly five `## ` headings, in this order, ≤400 words total:

```
## What got done
## Where the project stands
## What's next
## Issues you should know about
## How close to launch
```

Written by `humanizer`. Presentation only — every sentence traceable to an on-disk artifact, no new
numbers, **never cited as evidence**.

### A9. Events and metrics

`.pipeline/run-events.jsonl`, one object per line:

```json
{"ts": "<ISO-8601>", "type": "<event>", "run": "<run id>", "milestone": "M<n>", "kv": {}}
```

Metrics use **`null`, not `0`**, for "not instrumented". A zero must mean measured-zero — otherwise
every uninstrumented counter reads as a perfect score.

### A10. Retro — `.agent-development/runs/`

`NNN-<milestone>-<outcome>.md`, ≤220 lines. The outcome token set is **CLOSED**:

```
shipped   nogo   halted   abandoned   superseded   awaiting-ship
```

Consolidations every fifth run land in `.agent-development/consolidated/NNN-NNN.md` and rewrite
`ACTIVE-LESSONS.md` (≤100 lines).

### A11. Names

Kebab-case, 2–5 words, `^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$`; must state the problem; multi-step efforts
take a `-<n>` step suffix; never reused, never renamed. `rt_name_valid` (shell) and
`check_narrative.py --validate-name` (python) implement the same rules and are proven to agree.
