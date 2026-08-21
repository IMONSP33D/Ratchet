# `.agent-development/` — the learning loop

**What this is.** The part of Ratchet that makes each run improve the next one. **Who owns it:** the
loop itself — agents append, the `retro` seat writes, the human closes register rows.

**Tracked, scope-exempt, and NEVER pruned.** `gc-prune.sh` is forbidden from touching this tree, and
so is every delete rule. The corpus is the only evidence that a fix held; a window whose run docs were
deleted cannot defend a single dropped lesson. This is not a preference — the source pipeline deleted
its own corpus in one batched commit and had to reconstruct it from git.

## The four artifacts and their jobs

| artifact | job | written by | read by |
|---|---|---|---|
| `ACTIVE-LESSONS.md` | The binding ruleset. The **only** file in this tree any agent reads. Capped at `CAP_ACTIVE_LESSONS_LINES` (100). | consolidation only | orchestrator, at every run start |
| `PENDING-HUMAN-ACTIONS.md` | Ranked register of work only a human may do. Exists so "someone must rotate the key" stops being filed as a decision. | any agent appends; **only the human sets DONE** | orchestrator at run start; `session-start.sh` prints `BLOCKING` rows at `n>=3` |
| `INDEX.md` | One row per run: the register the outcome tokens feed. | `retro`, as its LAST step | anyone reconstructing a disputed verdict |
| `runs/` + `consolidated/` | The corpus. `runs/NNN-<milestone>-<outcome>.md` per run; `consolidated/NNN-NNN.md` every 5th. | `retro` | the next consolidation |

Also here: `_TEMPLATE-run-retro.md`, `_TEMPLATE-consolidated.md`, `metrics/` (one `run_metrics.py`
JSON sidecar per run, the mechanical record's source), and `proposals/` (supervisor changesets,
reviews and apply notes — see `proposals/README.md`).

## The loop

1. **Every run ends with a retro.** `retro` (opus) runs after the PR opens and before the Ship Prompt
   is answered — on **every** outcome, including halts and abandonments. Failures are the highest-value
   input. The run is not done until it exists; `check_done.py` fails without it.
2. **The retro reads the mechanical record FIRST** — `run-events.jsonl`, `run-metrics.json`,
   `findings.md`, checkpoint verdicts, `cmd-log`, the git log — and only then the narrative. Counters
   say what happened; reports say what the run *believed* about itself, and the gap between them is
   where the lessons are.
3. **Its payload is a table of typed, addressed refinements** (§7 of the template). "Improve the review
   process" is not a refinement. "Add X to `reviewer.md` §3" is.
4. **Every 5th run consolidates.** Merge by lesson identity, sum recurrence, drop resolved items *with
   the evidence the fix held*, promote `recurrence >= 3` to MUST-FIX, rewrite `ACTIVE-LESSONS.md`.
5. **The next run starts by reading `ACTIVE-LESSONS.md`.** That read is what closes the loop. A retro
   nobody reads is a diary; this one has exactly one consumer and a cap that forces it to stay readable.

**The boundary: `retro` proposes, it never applies.** `.claude/**` and the `.context/` corpus are
Tier 2b. An agent that can rewrite its own guardrails in response to being blocked by them has no
guardrails. Refinements are rows in a table.

## Recurrence is the whole mechanism

A lesson raised once is an anecdote. The same lesson at **recurrence >= 3** is a systemic defect: the
process has failed the same way three times without the cause being addressed, and it is promoted to
**MUST-FIX**. The same threshold applies to `PENDING-HUMAN-ACTIONS.md`, where it means something
stronger — the pipeline has correctly diagnosed a problem it cannot fix and has now paid for it three
times.

## The four loop rules the source corpus paid to learn

These are not style. Each one has a measured price tag.

**1. Refinements land in SCOPED commits, with the suite run between them. Never batched.**
One batched commit applying a whole retro's refinements broke a **closed** milestone's WIN row *and*
deleted the retro corpus itself. Land one refinement, run the suite, stop at the first red.
*The single exception is the supervisor-changeset pattern* (`proposals/README.md`): written by a party
barred from the control layer, audited by an independent reviewer with an explicit provenance caution,
and applied with replica verification. Under supervision an eight-file batch drove one failure class
from 12 to 0. Outside it, the batch is the risk.

**2. Every refinement row states an INVARIANT and enumerates EVERY instance of it.**
Five times running, a fix addressed at "this file, this line" reached the cited instance and not the
class — the canonical case landed in two files and stayed broken in two more for an entire window. The
row's `invariant` column is the grep pattern; the `all instances` column is that grep's output. A row
that names an instance and no invariant has not found the cause.

**3. Every MUST-FIX names a test, and that test is driven with a MISMATCHED payload requiring the
opposite verdict.** Checks that never saw a failing input sat green while their lesson kept recurring —
in the worst case a checker read one physical line while every payload sat on the next, and reported
nine correctly-wired lessons as unbound for two windows. A check that can only emit PASS is not a check
(CONTRACT §0.6). When you write the check, write the input that makes it fail, and commit both.

**4. Closures live in a greppable register, never only in a commit message.**
A fix recorded as "closed" solely in git history was silently reverted and nobody noticed, because
nothing on disk held the closure. Every closed item keeps its row: `PENDING-HUMAN-ACTIONS.md` rows go
to `DONE` with a date and are never deleted; resolved lessons move to the consolidation's RESOLVED
table with the evidence the fix held. The register is also the only record of how long the pipeline sat
blocked, which is the only way that cost ever becomes visible.

## Reading this directory later

Start with `ACTIVE-LESSONS.md` — current and short. Go to the newest `consolidated/` doc for a lesson's
reasoning. Go to `runs/` only for the evidence behind a specific run or a disputed verdict. `INDEX.md`
is the map.
