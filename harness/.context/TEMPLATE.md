# TEMPLATE.md — How to write this project's SPEC.md and MILESTONES.md

**What this is.** The single instruction sheet an agent reads in order to *write* `.context/SPEC.md`
and `.context/MILESTONES.md` for {{PROJECT_NAME}}. It is self-sufficient: every structure, id form,
frozen format and rule you need is here. It holds no project content and is not itself a contract.

**Who owns it.** The harness. It ships with Ratchet and is replaced wholesale on update. **Agents MUST
NOT edit it**, and neither should the human — a local edit is drift the next update overwrites.

**How to use it.** Read it once, end to end, before writing a line. Then: interview the human (§0),
gathering without composing; draft `SPEC.md` against §3 using the taxonomy in §2 and the AV register in
§4; draft `MILESTONES.md` against §5, writing every WIN row to the frozen spec in §6; re-read each row
and answer *what input makes this command exit non-zero?* (a row you cannot answer that for is not
finished); then hand both files to the human for the edit that makes them theirs — from then both are
Tier 2b (§1) and no agent may write them again.

RFC 2119 keywords (MUST, MUST NOT, SHOULD, MAY) are binding wherever they appear.

## 0. Gather the content — interview, never invent

The SPEC and MILESTONES are a *record of what the human wants*, not a plausible document about a project
of this shape. That distinction is the whole of this section. **You MUST NOT invent a requirement. You
MUST NOT invent a verify command.** If you do not know, you have two legal moves: **ask the human**, or
leave an explicitly marked line: `TODO(human): <the exact question, phrased so a one-line answer
resolves it>`.

A fabricated requirement is worse than a missing one. A missing one is visibly missing and someone
fills it. A fabricated one acquires an id, is cited by a test name, appears in a WIN row, passes a gate,
and is then believed — by the next agent, by the reviewer, and by the human who assumes it came from
them. No gate can tell an invented requirement from a real one; only you can, and only at the moment you
write it. The rule binds harder for verify commands: an invented command is executable fiction that
either fails for the wrong reason or passes vacuously and certifies nothing, forever.

**What to ask, until you can state it.** **Outcome:** what is true in the world when this is done, in
one paragraph, naming no technology. **Non-goals:** the adjacent thing a reasonable person would assume
is included, and is not. **Boundaries:** what crosses into the system from outside, and in what shape.
**Numbers:** every threshold, budget, limit and interval, with its unit — "fast" is not a number.
**Derived values:** any figure the system will be *trusted* on, and how the human would compute it by
hand. **Failure:** what must never happen, and what the system does when it happens anyway.
**Volatility:** which facts the design leans on that are owned by someone else (§4). **Proof:** per
item, asked out loud — what command would show this working?

**Rules while gathering.** Prefer the human's own words for anything load-bearing; paraphrase costs
precision. Record a range as a range, and which end the design must survive. "Obviously" and "the usual"
mark an unstated requirement — write it down. Never resolve a contradiction silently. An answer inferred
from existing code is a hypothesis marked `TODO(human):` until confirmed: code is evidence of what was
built, never of what was wanted. Leave the TODOs in — a SPEC shipping with three honest TODO lines is
usable; one with three invented paragraphs is a trap that reads as complete.

## 1. The four-directory ownership partition — the harness's core idea

Ratchet's central claim: autonomy is safe exactly when **ownership is a directory boundary, not a
promise**. Four trees, four owners, enforced by `scope-guard.sh` and `guard.sh` rather than intent:

| Tree | Owner | Agent access | Lifetime |
|---|---|---|---|
| `.claude/` | The control layer | **Unwritable.** The control set within it is never-escalatable; the rest is refused by default, changeable only by an approved byte-exact write. | Permanent |
| `.context/` | The human | **Read-only, Tier 2b.** `SPEC.md`, `MILESTONES.md`, `PIPELINE.md`, `CLAUDE.md`, this file. Agents propose changes via `DECISIONS.md` and the retro. | Permanent |
| `.pipeline/` | The agents | Read/write scratch. Pruned by `gc-prune.sh`; mostly gitignored. | **Run-scoped** — archived at gate closure |
| `.agent-development/` | The learning loop | Append-only in spirit; scope-exempt; **never pruned**. | Permanent |

Everything else — source, tests, docs, evidence — is ordinary work product, gated by the run's manifest.
Two consequences: **a rule the agent could edit is not a rule** (hence the control set is
never-escalatable even under an approval — the files that decide what an approval means cannot be changed
by one), and **a run-scoped tree MUST be cleared at gate closure** (a manifest from a closed milestone
gating an unrelated session is a real failure mode). Writing SPEC.md and MILESTONES.md is the one moment
an agent legitimately produces `.context/` content: once, before the first run, then handed over.

## 2. Requirement-ID taxonomy

Every requirement has a stable id; tests, commits, WIN rows and DECISIONS entries cite these ids, and
those citations are what the proof map and the mission trace follow.

| Prefix | Means | Form | Proven by |
|---|---|---|---|
| `REQ-` | A functional requirement — the system MUST do this | `REQ-<MODULE>-<nn>` | A named passing test citing the id |
| `SEC-` | A security requirement — a control, a boundary, a refusal | `SEC-<nn>` | A named passing test, or a closed security finding |
| `TEST-` | A testing requirement — how the suite itself must behave | `TEST-<nn>`, properties `TEST-P-<nn>` | The suite's own configuration and gates |
| `INV-` | An invariant — a relation that holds at all times | `INV-<DOMAIN>-<nn>` | A property test over generated inputs |
| `AV-` | An assumption to verify — a volatile external fact (§4) | `AV-<nn>` | Captured raw evidence plus a `DECISIONS.md` entry |

`REQ-` is namespaced by module because functional requirements grow per module and a flat sequence
becomes unreadable. `SEC-` and `TEST-` are flat: cross-cutting and few. `INV-` is namespaced by the
domain it governs.

1. **Ids are permanent and never reused.** A replaced requirement gets a NEW id; the old is marked
   SUPERSEDED in place and keeps resolving forever. A citation that resolves to nothing still *reads* as
   though it resolves — that is the failure mode. Numbering is per-namespace and monotonic: never
   renumber to close a gap.
2. **Every id is stated so it can fail.** "Handles errors gracefully" is not a requirement; "an unhandled
   exception in the main loop MUST be logged with a stack trace, increment the breaker, and not terminate
   the process" is. A requirement no test can cite is a design note — move it to prose.
3. **Adding a namespace** is a governing-corpus change: a `DECISIONS.md` entry and a human edit. Declare
   its prefix and exact form, what belongs in it and what does not, whether it is flat or namespaced, and
   **what artefact proves one** — the last is the one people forget, and the one that decides whether a
   WIN row can cite it.

## 3. SPEC.md — structure

Every heading is mandatory. A section with nothing in it says "None — <why>" explicitly; an empty section
reads as an oversight rather than a decision.

| § | Heading | What it holds |
|---|---|---|
| — | Title + ownership | Version, date, companions; "Human-owned, Tier 2b; agents MUST NOT edit"; and what *frozen* means: an agent may not change a requirement to make a test pass. Where reality contradicts the document the orchestrator records a `DECISIONS.md` entry choosing the safest reversible option; the document changes by human edit only. |
| 1 | Purpose, scope, non-goals | One paragraph each. **Non-goals** is the section people skip and the one that stops scope creep three milestones later; each is a boundary a later milestone may not cross without a human edit. |
| 2 | Requirement-ID taxonomy | The table from §2 above, plus this project's module tokens. |
| 3 | Architecture | Components and what each is responsible for; the architect partitions against these boundaries, so draw them where you want work to fan out. One paragraph on the execution model and what tests substitute for it. |
| 4 | Repository layout (canonical) | The tree as you want it enforced, not as it happens to be. M0's first WIN row usually diffs the real tree against this. |
| 5 | Core domain models | The types that cross module boundaries, with fields. Two rules belong here as `REQ-` ids rather than prose because they erode: external payloads are parsed into declared types at the boundary; business logic never reads a raw untyped payload. |
| 6 | Formulas & golden values | Every derived number the system will be trusted on: the formula, then hand-derived goldens (§8). |
| 7 | Functional requirements by module | One block per §3 component. Each: stable id, MUST/SHOULD/MAY statement, stated so it can fail. If you cannot describe the input that violates it, rewrite it. |
| 8 | Configuration | Every tunable with its default, in one place. A value declared here MUST NOT appear as a literal in logic — that is what makes an AV outcome a config change rather than a code change. Secrets come from the environment only. |
| 9 | Security requirements | `SEC-` ids, each independently testable. Name the files implementing the auth/secret boundary; those are a Hard Stop surface. |
| 10 | Testing requirements | `TEST-` ids constraining the **suite**, not the system: tiers and markers, coverage gates, property obligations, golden obligations, CI behaviour, flake policy, fixture scrubbing. |
| 11 | Invariants | `INV-` ids: relations that hold at all times, property-tested. They survive refactoring, so state them precisely. |
| 12 | Critical-file coverage set | The short, load-bearing list where a coverage regression is a defect rather than a metric: core math, security boundary, parsers, irreversible paths. A gate script reads this list. |
| 13 | Observability & resource budgets | What is logged, counted, and allowed to be consumed. Budgets stated as numbers become WIN rows; budgets stated as adjectives become arguments. |
| 14 | AV register | §4 below. |

## 4. The AV register — volatile facts get verified, never assumed

**What belongs.** A fact about the world *outside the repository* that the design depends on and can
change without notice: an external interface's shape, a rate limit, a quota, a third-party default, a
published identifier, a regulatory date — anything you would otherwise write as "as of today, X is Y".
**What does not:** internal design choices (`DECISIONS.md`), anything the suite can prove (`REQ-`), and
preferences. **The test:** *if this fact changed silently tomorrow, would the system be wrong and the
tests still green?* If yes, it is an AV item.

**Lifecycle: `open` → `measured` → `configured`.**

| State | Meaning | Where it lives |
|---|---|---|
| **open** | Declared in the register with the source it must be verified against, and a **conservative** default in config. The design must survive the unfavourable branch. | `SPEC.md` §14 |
| **measured** | A run verified it against a live source and captured raw evidence under `docs/evidence/M<n>/probes/`; the measurement is recorded in a `DECISIONS.md` entry citing the AV id. | Evidence + DECISIONS |
| **configured** | The measured value is written into config defaults; the row records the milestone that resolved it and the evidence path. | Config + register |

**An AV outcome updates config defaults and `DECISIONS.md` — never code literals.** A measured value
hard-coded into logic has left the register and can never be re-measured. Register shape in `SPEC.md`
§14, and its mirror ledger in `MILESTONES.md` — one list, not two:
`| ID | Assumption (config-driven; never hard-coded) | Conservative default | Verify against | Resolves at |`
and `| AV | Item | Resolves at | State | Evidence |`.

1. **Verification of each AV item MUST be a WIN row** in the milestone where it resolves. An item nobody
   is required to verify is a comment.
2. **While an item is open, carry both branches.** If the unfavourable branch changes a result, report
   both, labelled. Reporting one series while the assumption is unresolved is a defect.
3. **A verification that contradicts a frozen contract** is the orchestrator's to decide — a
   `DECISIONS.md` entry, and a Decision Card only if it moves a load-bearing constant.
4. **Ground truth beats documentation.** Where an item can be read off a real artifact, that artifact is
   the source and any document is secondary — including this one.
5. **Some items never close.** One that can regress carries a re-check cadence, and the register says so.
6. **Keep one row for the project's central unproven assumption** even with no other AV items: the one
   whose failure ends the project. Name it, name the milestone that tests it, and let that milestone be
   allowed to return NO-GO. A NO-GO on the merits is a successful run.

## 5. MILESTONES.md — structure

`MILESTONES.md` is the **sole source of milestone numbering**: where any other document says M<n>, it
means the milestone defined here. Human-owned, Tier 2b. The file is an ownership block, the "How to
read a WIN row" table (§6.1 — copy it in), a milestone map, one block per milestone, and the AV ledger.

The **milestone map** is one row per milestone — `| M | Name | Run type | Gate character |` — and is the
index every other document reads. If any milestone contains an unattended validation window, state the
minimum wall clock to the final milestone and say plainly that no amount of compute compresses it.

**Milestone skeleton** — every block has exactly these parts:

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

**Run types.** `standard` — one agent run, Stages 0–6, ending in a Ship Prompt. `standard + soak` — a
standard run that launches a long unattended validation run at its close; the soak's WIN rows are
evaluated by a **separate later run**. `human-executed` — a human performs the milestone; agents may
build tooling and analyse results but MUST NOT perform the gated act.

**Run scope is ONE milestone**, or a declared WIN subset of one.

## 6. The WIN row — frozen format

```
| WIN-M<n>-<nn> | <name> | <requirement ids> | <verify command> | <evidence path> |
```

Exactly five fields, in that order. A parser reads this; changing the shape breaks its reader.

### 6.1 How to read a WIN row

Every WIN row is **script-decidable**: it has a verify command that exits 0 or non-zero, and a human never
adjudicates it.

| Field | Meaning |
|---|---|
| **WIN ID** | `WIN-M<n>-<nn>`, zero-padded. A **coordinate**, not a label: positional, never renumbered, never reused. Referenced in test names and commits. |
| **Name** | Kebab-case, 2–5 words, states what the row proves. What humans cite; unique across the project's findings, lessons, decisions and pending actions. |
| **Requirements** | The `REQ-`/`SEC-`/`TEST-`/`INV-`/`AV-` ids this row proves. At least one, or `—` for a row proving a structural property with no requirement id. |
| **Verify** | The command. Exit 0 = pass. A wrapper target (`make win-m<n>-<nn>`) unless the invocation is short, stable and self-explanatory. |
| **Evidence** | Where the raw output lands, under `docs/evidence/M<n>/`. |

### 6.2 What makes a verify command VALID — all five MUST hold

| Property | Meaning | Fails if |
|---|---|---|
| **Script-decidable** | It is a command, not a description | "review the logs and confirm" |
| **Exit 0 = pass** | Exactly. Non-zero = fail. Nothing else is consulted | It prints PASS but exits 0 unconditionally |
| **Deterministic** | Same commit, same inputs, same verdict | It samples live data with no recorded fixture |
| **Network-free** | Unless the row exists precisely to prove an external interaction, and is marked as such | A unit-tier row silently reaches the network |
| **Non-interactive** | No prompt, no TTY requirement, no pager | It opens a pager, or waits for a keypress |

A command that only ever emits PASS is not a check. **If you write a verify command, be able to state
the input that makes it fail.**

**Wrapper-target convention.** A verify command SHOULD be a named task-runner target, `win-m<n>-<nn>` to
match the row, wrapping the real command. Three reasons: the row survives a tooling change (the wrapper
moves, the Tier 2b document does not); a human reproduces one row with one command read off the table;
the command can be invoked in isolation by the gate and by evidence capture. A bare inline invocation is
acceptable when short, stable and self-explanatory (`pytest -k redaction`); a multi-clause shell pipeline
MUST be wrapped.

**Fixtures, not networks.** Where a row proves behaviour against an external interface, the row running in
the ordinary suite verifies against a **recorded, scrubbed fixture**, and a separate, explicitly-marked
capture row reaches the live source. Never model an external interface from a guess: capture a real
response, scrub it, model from that.

### 6.3 The setup-defect rule

**A WIN row with no verify command is a SETUP DEFECT.** It is raised to the human, never adjudicated by
judgment, and never satisfied by an argument that the condition is obviously met. The orchestrator cannot
decide the row passed; a checkpoint reviewer cannot CLEAR a checkpoint resting on it; a NO-GO cannot be
earned on a row that never ran. The only remedy is a human edit supplying a command. Which is why:
**write the verify command before you write the condition.** A condition you cannot write a command for
is one you do not yet understand, and it will reach a run as an unadjudicable row.

### 6.4 Conditions are stated so they can fail

Write the condition as the thing that would be false if the system were wrong, with the number in it:
"coverage is good" is not a WIN row, "critical-set coverage ≥ 95%" is. Where the honest answer may be
negative, say so — a **measurement** row is satisfied by reporting the measurement, including
"inconclusive". A row that can only be satisfied by a favourable result is a target, not a test, and it
will be met by tuning. Prefer **refusal** rows to existence rows: "startup refuses a world-readable key"
proves the system refuses, while "a permission check exists" proves nothing, and existence rows are the
most common way a milestone passes without proving anything. Grep-style rows ("this literal appears
nowhere in the source tree") are excellent precisely because they cannot be argued with.

## 7. Naming doctrine

Findings, lessons, decisions, pending actions, WIN row names and branches are referenced by **name**.

- Format: kebab-case, 2–5 words, `^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$`.
- **The name states the problem**: `gate-blames-wrong-actor`, not `issue-3`.
- **Rejected as too generic (hard list):** `fix-issue fix-bug misc-problem update-thing general-fix
  various-fixes minor-issue small-fix quick-fix todo-item`, and any name matching
  `^(fix|update|change|misc|various|general|temp|new|old)-`.
- **Multi-step efforts:** one name plus a step counter — `harness-adjustment-1`, `-2`. Regex
  `^<name>-[0-9]+$`, where `<name>` is itself valid.
- **Permanent. Never reused, never renamed.** A superseding item gets a NEW name plus a
  `Supersedes: <old-name>` line.
- Uniqueness is checked mechanically at filing time across findings, active lessons, pending actions
  and decisions.
- Decisions carry a numeric id **and** a name: `DEC-007 · retry-cap-tightened`. The number sorts and
  names the archive file; the name is what humans read and cite.
- WIN rows keep positional ids (`WIN-M1-03` is a coordinate) **and** a name column.
- Branches: `agent/<task>`, `<task>` kebab-case per the same rules. Work reaches `{{BASE_BRANCH}}` only
  through the PR.

## 8. Goldens, test names, selectors, commits

**Goldens.** A golden is a hand-derived expected value — computed by a human, by hand or by an independent
method, written into the SPEC in the formula section that defines it, with the derivation shown. Every
golden becomes a named test with the value as a **literal**, never computed at test time, and the
derivation goes in the docstring so the next reader can check the number without leaving the file. **A
golden is never generated by the implementation** — a value produced by the code under test proves only
that the code agrees with itself, which is the single most common way a golden suite becomes decorative.
Changing a golden requires a DECISIONS entry in the same commit citing what made the previous value
wrong. Goldens pin points; `TEST-P-` properties pin the shape between them.

**Tests carry requirement ids** in their names, separators normalised to the language's identifier rules:
`test_bucket_total_rounds_up_REQ_AGG_02`, `test_key_permissions_refused_SEC_02`. The id in the name is
what the proof map, the mission trace and `check_done.py` follow; a requirement whose id appears in no
test name is unproven regardless of how well it is implemented.

**Selectors are load-bearing.** The architect freezes, per WIN row, the selector substring that row's
verify command uses, and a test serving a row MUST contain that substring in its name. Renaming a test so
it no longer matches **silently removes it from the row's proof** while the suite stays green; therefore
a rename that changes a selector match is a contract change, needs a DECISIONS entry, and is an audit
item exactly like modifying a test.

**Commits: Conventional Commits, one per green TDD cycle.** Subject `<type>(<scope>): <subject>`, types
`feat fix test refactor docs chore build ci perf`; body says what changed and why, referencing
requirement ids; footer `DEC-nnn · <name>` when a decision was recorded in the same commit.

One green cycle = one commit (red → green → refactor → commit), not "one feature", not "one session".
Reference requirement ids — that is how the mission trace reads history. A decision lands in the same
commit as the change it authorises, never after. A diff exceeding `COMMIT_SCOPE_LINES` means cycles were
batched; split it. Never `--no-verify`. The test-writer's red commit and the developer's green commit are
separate commits by separate seats: one commit containing both is indistinguishable from test-after.

## 9. Frozen artifact formats (parsers read these)

**Evidence layout.** `docs/evidence/M<n>/` holds `proof-map.md` (GENERATED by `proof_map.py`, never
hand-edited), `<win-name>.txt` per row (the raw output of its verify command), `probes/<probe>.txt`
(verbatim, unedited), and `postmortem.md` only on a NO-GO or a halted validation run. Raw output,
unrewritten — a description of output is a second telling that can drift. The proof map is generated at
HEAD from a contracts table whose column names **`win`** and **`selector`** are frozen, and **every WIN row
MUST collect ≥1 test**; zero is either a missing test or a selector defect, both fixed, neither
adjudicated. `docs/evidence/` is tracked, never pruned, and cited by path rather than pasted.

**DECISIONS entry** — `.context/DECISIONS.md` (hot), `.context/archive/decisions/` (cold):

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

Hot file: soft cap 250 lines, hard cap 300. **Appending a decision must never be the failing action** —
over the hard cap the checker emits `ROLLOVER-REQUIRED` and the append is still permitted.

**Findings ledger** — `.pipeline/findings.md`, pipe table, header frozen
`| name | source | severity as filed | file:line | finding | disposition | rationale | DEC |`.
`severity as filed` is what the reviewing agent filed and is **never edited**; disposition is a separate
column, one of `FIXED` `ACCEPTED` `DEFERRED` `WAIVED`. `FIXED` rationale ≤40 words;
`ACCEPTED`/`DEFERRED`/`WAIVED` ≤80 words **and a DEC id is mandatory**. No probe transcripts in cells —
cite an evidence path. Board raw outputs (`.pipeline/reviewer-findings.md`, `-security-findings.md`)
carry one numbered finding per item, `1.` at line start; the count is reconciled against the ledger.

**Manifest.** `.pipeline/plan-files.txt`, one repo-relative path per line.
`.pipeline/manifest-amendments.txt`, `<path> <DEC-id> [note]`, one per line — one shared parser serves
the Stop gate and `check_done.py`, so a line satisfying one satisfies the other.

**Checkpoints** — `.pipeline/checkpoints/`: `<n>-<stage>-jump.md` (`checkpoint-scribe`; 7 sections,
≤500 words) · `<n>-<stage>-evidence.txt` (`checkpoint-evidence.sh`; **script-written only**, never
edited, never curated) · `<n>-<stage>-clear.md` (`clear-reviewer`; ≤200 words, names its spot-check and
what it found, final line alone `CLEAR` / `BLOCK: <reasons>` / `ESCALATE: <reason>`) ·
`<n>-<stage>-fast.md` (the orchestrator; the FAST checklist, each item answered, one verdict).

**Ship consent** — `.pipeline/ship-consent.json`, written BEFORE the merge, with keys
`pr` `head_sha` `base` `question` `options_offered` `answer` `answered_at`. `guard.sh` refuses a merge or a push to `{{BASE_BRANCH}}` unless the file exists and its `pr` and
`head_sha` match the command and HEAD. It is a **record**, not the control; branch protection is the
control.

**Recap** — `.pipeline/recap.md`, exactly five `## ` headings in order: `What got done` /
`Where the project stands` / `What's next` / `Issues you should know about` / `How close to launch`.
Presentation only; never cited as evidence.

**Events** — `.pipeline/run-events.jsonl`, one object per line: `{"ts","type","run","milestone","kv":{}}`.
Metrics use **`null`, not `0`**, for "not instrumented" — a zero must mean measured-zero, or every
uninstrumented counter reads as a perfect score.

**Retro** — `.agent-development/runs/NNN-<milestone>-<outcome>.md`. The outcome token set is **CLOSED**:
`shipped nogo halted abandoned superseded awaiting-ship`.

## 10. Minimal worked example

Shape only. Two rows, deliberately. Real milestones have more; none is better than these two unless it
is equally decidable.

```markdown
# M0 — Scaffold and configuration spine

**Goal.** A repository where every later milestone has a place to put its code and its proof, and
where `{{VERIFY_CMD}}` runs green on an empty-but-valid tree.
**Entry.** Empty or near-empty repository; the control layer installed and its self-test passing.
**Run type.** standard

| WIN | Name | Requirements | Verify | Evidence |
|---|---|---|---|---|
| WIN-M0-01 | canonical-tree-matches-spec | — | `make win-m0-01` | `docs/evidence/M0/canonical-tree-matches-spec.txt` |
| WIN-M0-02 | config-rejects-missing-key | REQ-CFG-01 | `make win-m0-02` | `docs/evidence/M0/config-rejects-missing-key.txt` |

**Exit gate.** Both rows green; PR merged.
```

`win-m0-01` diffs the real tree against the SPEC §4 manifest and exits non-zero on any difference — a
structural row, cheap, and it stops drift for the whole project. `win-m0-02` is a **refusal** row: it feeds
a config with a required key removed and asserts startup fails naming that key. Both are script-decidable,
deterministic, network-free and non-interactive, and for both you can state the input that makes them
fail. That is the entire standard.
