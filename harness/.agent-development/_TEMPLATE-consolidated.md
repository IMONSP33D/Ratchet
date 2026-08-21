# Consolidated NNN–NNN — <n> runs

> **Template for every 5th run. Owned by the `retro` seat.** Copy to `consolidated/NNN-NNN.md`.
>
> **Consolidation is merge by lesson IDENTITY, not concatenation.** If this document is roughly the
> length of five run docs, nothing was consolidated — the cutting is the work. Report the number of
> rows dropped and why. "Kept everything" is a consolidation failure and must be reported as one.
>
> This is the ONLY document permitted to rewrite `ACTIVE-LESSONS.md`.

Window: runs NNN..NNN · `<date>`..`<date>` · outcomes: <n shipped, n nogo, n halted, n abandoned,
n superseded, n awaiting-ship>

**Counting rule applied.** <State it explicitly. A run superseded by its own continuation contributes
ONE increment, not two — documents and counted runs are different numbers, and every recurrence figure
below is over counted runs. Say which is which: `<n> documents / <n> counted runs`.>

## 1. Window summary

<One paragraph: what these runs were, and the single most important thing they collectively revealed.
Not a list of the five — the **pattern across** them. If the window has no pattern, say that; a window
of five unrelated failures is itself a finding about the process.>

| | measured |
|---|---|
| documents / counted runs | |
| milestones closed | |
| WIN rows evidenced | |
| findings filed / CRITICAL / HIGH accepted unfixed | |
| Decision Cards raised / judged to have earned the interruption | |
| human-action rows opened / closed | |
| refinements proposed / landed | |

## 2. Aggregate mechanical record

Assembled from the per-run `metrics/NNN-*.json` sidecars. **Do not re-derive a figure by hand** — if a
sidecar is wrong, the row says so and keeps the wrong figure.

| metric | r-NNN | r-NNN | r-NNN | r-NNN | r-NNN | trend |
|---|---|---|---|---|---|---|
| work / wall seconds | | | | | | |
| work as % of cap | | | | | | |
| dispatches | | | | | | |
| stop-gate blocks | | | | | | |
| guard blocks (top rule) | | | | | | |
| checkpoint BLOCKs | | | | | | |
| findings (C/H/M/L) | | | | | | |
| Decision Cards | | | | | | |
| escalations req / approved | | | | | | |
| caps hit | | | | | | |

**Trend reading.** <Two sentences. Is the process getting faster, cheaper, or more correct — and which
is being traded for which? A trend with no trade named was not looked at hard enough.>

## 3. Merged lessons, ranked

Merged by **underlying cause + target file**, never by wording. Five runs describing one cause five
different ways is **one lesson at recurrence 5**, not five lessons. Ranked by `recurrence × cost`,
where cost comes from §2 and not from how annoying the lesson felt.

| rank | lesson name | n | target file | lesson | cost evidence (from §2) | status |
|---|---|---|---|---|---|---|
| 1 | | | | | | MUST-FIX \| binding \| watch |

**Promoted to MUST-FIX this window (recurrence >= 3):** <list, or `none`>
For each, state plainly: the process has now failed the same way `n` times without the cause being
addressed, and this is what it has cost cumulatively. Name the `assert:` that will fail on the next
recurrence — a promotion without a named test is a promotion to a stronger adjective.

## 4. REQUIRED — MUST-FIX lessons that recurred WITH THEIR NAMED TEST GREEN

**This is the section the source corpus never had, and its absence cost nine runs.** Seven already-
MUST-FIX lessons recurred in a single run, each with a passing `assert:` beneath it, and no artifact
anywhere asked why. Answer it here, every window, even when the table is empty.

A green assert beside a recurring lesson means **the assert pins an INSTANCE while the lesson is an
INVARIANT**. The test is not wrong; it is *narrower than its subject*. That is a defect in the test, not
in the lesson, and it is invisible to every other check in the harness.

| lesson name | `assert:` | test verdict | the recurrence it did not catch | why the test missed it | remedy |
|---|---|---|---|---|---|
| | `Test...` | green | <the instance> | `pins-an-instance` \| `payload-never-reached-subject` \| `never-driven-with-a-failing-input` \| `subject-moved` | <broaden the assert to the invariant \| add the mismatched-payload drive \| retire and re-derive> |

**Rule.** Every row here produces a §5 refinement against `test_hooks.py` in the SAME window. A row
that only observes the gap re-files itself next window — that is `fix-reaches-instance-not-class`
applied to this document.

If the table is empty, state the check you ran: for each MUST-FIX, `n` did not increase **or** its
assert went red. "None observed" without that check is not an answer.

## 5. Merged refinements still outstanding — by target file

| target file | merged from | what is still owed | n | invariant |
|---|---|---|---|---|
| | | | | |

**Dropped from the tail, and why:** <count and one line each. Nothing is dropped for being old.>

## 6. RESOLVED — what was fixed and STAYED fixed

| lesson name | what fixed it | evidence it held | window it survived |
|---|---|---|---|
| | | | |

**Never delete a resolved lesson silently.** This table is the record that a particular fix *worked*,
and it is the only defence against re-litigating it in a later window. A resolved row with no evidence
column is an assertion that it was fixed, which is `unaudited-self-account`. If a fix's evidence is
"nobody complained", it is not resolved — it is unobserved, and it stays at `watch`.

## 7. Dropped

| lesson name | why dropped |
|---|---|
| | |

## 8. Rewritten `ACTIVE-LESSONS.md`

- Lines before: `<n>` · after: `<n>` (cap `CAP_ACTIVE_LESSONS_LINES` = 100)
- Promoted: `<n>` · demoted: `<n>` · dropped: `<n>` · new: `<n>`
- Every remaining lesson carries a green, drivable `assert:`? <yes/no — list any that do not>
- <If the rewrite hit the cap, name the item cut LAST and why it lost. That sentence is the ranking.>

**Seeded lessons (run-000).** <At the FIRST consolidation this is mandatory: re-evaluate all ten
seeded lessons against local evidence. Confirm each with a local instance, demote to `watch`, or drop
with a reason. A seeded lesson carried a second time with zero local instances is padding and is cut.>

## 9. Meta — is this loop earning its cost?

<Honest paragraph. The loop costs one opus dispatch per run plus this consolidation. Has any refinement
from the previous window actually been **applied**, and did it move a number in §2? If two consecutive
windows produce no applied change, say so — recommending that this loop be reduced or removed is a
legitimate output of this loop, and refusing to consider it is how the loop becomes ritual.>

## 10. Hypotheses carried into the next window

| name | status entering the next window | KILL CONDITION |
|---|---|---|
| | `carried` \| `confirmed ×n` \| `KILLED` | |

**LAST STEP — append the consolidation row to `INDEX.md`**, marked `CONSOLIDATED NNN-NNN` in the
milestone column.
