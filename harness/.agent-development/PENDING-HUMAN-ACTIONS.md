# PENDING-HUMAN-ACTIONS.md — the ranked register of things only a human can do

**Owner: the human.** Agents append rows. **Only the human sets `DONE`.** Tracked, scope-exempt,
never pruned.

## What this is for

A run regularly discovers work it is not permitted to perform: a Tier 2b file that must change, a key
that must be rotated, a server-side setting that must be enabled, a `.context/` edit only the owner may
make. Before this register existed there was nowhere to put those, so they went into `DECISIONS.md` —
which made the decision log longer on the run-start read path *and* turned a to-do into something
shaped like a settled decision. The worst of both: a bloated hot file, and a task nobody tracked
because it read as already handled.

**This register exists so that "someone must rotate the key" stops being filed as a decision.**
A decision is a choice that has been made. This is a list of choices that have not.

## Ranking, and why it is the whole design

An unranked flat list is how a real fix survives **seven filings**: one row among twenty-three, no
recurrence column, and nothing at run start saying *this one will cost you again today*. The retro
counted recurrence; the artifact the human acted from did not.

So every row carries **`recurrence`** — the number of runs that have raised it — and the register is
ordered by `recurrence` **descending**. **`session-start.sh` prints every `OPEN` row at
`recurrence >= 3`** into the run's opening context. The threshold is deliberate: an unfiltered print of
twenty-three rows teaches the reader to skip the section, which is exactly how the webhook row below
was ignored for five consecutive runs.

Rows are **not** severity-tagged. The register carries one ranking signal, and it is the measured one;
a second, self-assigned axis would compete with it and lose. How badly a row hurts is stated in
`why it blocks`, in prose, where a human reads it.

**A row at `recurrence >= 3` is a systemic defect by this harness's own rule.** For a lesson,
recurrence 3 promotes to MUST-FIX. For a human action it means something stronger and more
uncomfortable: the pipeline has correctly diagnosed a problem, cannot fix it itself, and has now paid
for it three times.

## Rules of use

- **Appending (any agent, orchestrator included).** One row. Never a paragraph, and never here if the
  pipeline could have done it itself — a task filed here that an agent was permitted to perform is a
  defect the retro is meant to find. Names follow CONTRACT §6 and are validated at filing time.
- **A row states the EXACT command or click-path.** "Configure the webhook" is not an action. A
  remediation command goes stale like any other artifact; if you find one that no longer applies, fix
  the row and say so in the note — a stale command inside a `BLOCKING` row reads as an action taken.
- **Closing (human only).** Set `status` to `DONE` and add the date. **Never delete the row.** The
  register is also the evidence of how long the pipeline sat blocked, which is the only way that cost
  becomes visible. A closure that lives only in a commit message is not a closure — the source corpus
  had a "closed" fix silently reverted because nothing on disk held the ruling.
- **Reading (orchestrator, at run start).** Any `OPEN` row whose subject this run touches is a
  constraint on the plan, not a footnote. If the run cannot proceed without one, that is a Decision
  Card, not a workaround.
- **Incrementing `recurrence` (retro, once per run).** Increment only if the row's condition was hit
  **again** this run, and say so in the retro's §6. Never increment for merely re-reading the row —
  recurrence counts incidents, and an inflated count corrupts the ordering it exists to drive.

## Register

| name | filed | what the human must do | why it blocks | recurrence | status |
|---|---|---|---|---|---|
| `branch-protection-missing` | install | On GitHub: **Settings → Branches → Add branch protection rule** for `main` → tick *Require a pull request before merging* and *Do not allow bypassing the above settings*. CLI equivalent: `gh api -X PUT repos/<owner>/<repo>/branches/main/protection -f required_pull_request_reviews.required_approving_review_count=1 -F enforce_admins=true -F required_status_checks=null -F restrictions=null`. Verify with `gh api repos/<owner>/<repo>/branches/main/protection`. | A **server-side** setting no agent can reach. Every client-side merge control in this harness is a *record*, not an enforcement: `SHIP_CONSENT` is written by the agent that merges, and `guard.sh` runs on the agent's own machine. Branch protection is the only half that actually holds, and CONTRACT §5.7 says so in writing. Until it is on, the ship flow's second factor is an honour system. | 0 | OPEN |
| `spec-and-milestones-unfilled` | install | Fill `.context/SPEC.md` and `.context/MILESTONES.md` with this project's real requirement ids and WIN rows. Every WIN row needs a **script-decidable verify command** (exit 0 = pass) in the frozen format `\| WIN-M<n>-<nn> \| <name> \| <requirement ids> \| <verify command> \| <evidence path> \|`. Verify with `python .claude/hooks/proof_map.py --milestone M1` — it must collect >=1 test per row. | Both files are Tier 2b (`GOVERNING_CORPUS`) and no agent may write them. Until they carry real rows, the milestone gate has nothing to close on: `check_done.py` cannot evidence a WIN row that does not exist, and a WIN row with no verify command is a **setup defect** the pipeline is required to raise rather than adjudicate. The harness installs inert without this. | 0 | OPEN |
| `webhook-never-configured` | install | Export `RATCHET_WEBHOOK_URL` in the environment the agent runs in — **https only**. Then fire it deliberately once to prove the path: `bash .claude/hooks/notify.sh --test`. Do not paste the URL into any tracked file. | The value is a secret, and Hard Stop 1 forbids any agent from handling one. Until it is set, an escalation or a halt in an unattended run **pages nobody** and the run halts into silence. `session-start.sh` warns at every run start; that warning is not a substitute. | 0 | OPEN |

### Note on the three install-filed rows

All three rows above are pre-filed at install, all at `recurrence 0` — they are prerequisites the
harness cannot function safely without, not incidents that have recurred. `branch-protection-missing`
and `webhook-never-configured` are ported from the source pipeline, where **both sat OPEN for five
consecutive runs**: the webhook was a single environment variable, and three run-parks paged nobody
while it was unset; branch protection left the only real merge enforcement absent for the entire first
window, during which the pipeline's own documents correctly described it as the only control that
holds. Neither was hard. Both were invisible, because they were rows in an unranked list nobody
printed AND their recurrence never climbed past the print threshold, since nothing increments
recurrence except a retro. `spec-and-milestones-unfilled` is filed for the same reason: it blocks
every gate from install day one, at recurrence 0, forever, unless something prints it regardless.

**This is why `session-start.sh` prints every row filed at install (`filed == install`) unconditionally,
in addition to the `recurrence >= 3` rows** — a recurrence-only filter cannot be the whole rule when the
rows most worth printing are, by construction, rows whose recurrence will never rise on its own. Doing
all three now costs about five minutes.

<!--
Row format (frozen - parsed by session-start.sh and check_done.py):
| <name> | <YYYY-MM-DD or "install"> | <exact command or click-path> | <why the pipeline cannot do it> | <n> | OPEN or "DONE YYYY-MM-DD" |

Ordering: recurrence descending. OPEN rows print at SessionStart when recurrence >= 3 OR filed == install.
Names: CONTRACT section 6 - kebab-case, 2-5 words, states the problem, permanent, never reused.
-->
