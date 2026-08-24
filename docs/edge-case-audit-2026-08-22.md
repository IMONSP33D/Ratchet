# Edge-case audit — Ratchet agentic pipeline (2026-08-22)

**Repo:** `C:\Users\imsam\Desktop\Ratchet`, reached through the Claude desktop bridge. Work was
done on a container copy of `harness/`, verified with the full hook suite between every change, and
each change committed straight to `main` on the device.

**What this is.** A follow-on to `docs/audit-2026-08-22.md`. That audit checked the harness against
its stated goal. This one goes the other direction: it probes the harness's *own* control layer and
learning loop for edge-case defects — inputs that are plausible but slip a gate, gates that pass
while their contract is violated, and one design promise the code did not keep. Two independent
subagents hunted the learning loop and the enforcement layer; every finding below was reproduced
with a minimal case before it was touched.

Ten defects were found. **Eight are fixed, committed, and pinned by new regression tests.** Two are
written up with proposed fixes but left for you to decide on, because they touch the escalation
crypto core or a broad parsing surface and deserve a Decision Card rather than a same-session patch.

---

## Verified state after this session

- Full hook suite on the container copy (byte-identical to what was committed):
  **197 run, 190 passed, 0 failed, 7 skipped**. The suite grew from 180 to 197 as 17 new regression
  tests were added across six new test classes.
- On the device: the QUICK tier (the security-wall + meta-invariant subset) is **52 run, 51 passed,
  0 failed**, and all six new test classes pass. `check_done.py --selftest` (19/19),
  `check_narrative.py --selftest`, `run_metrics.py --selftest`, `scope-guard.sh --selftest`,
  `guard.sh --selftest`, and `hooklib.sh --selftest` all PASS.
- Working tree is clean; all eight commits are on `main` (`2cf8bcd` … `37ad24f`). Nothing pushed
  anywhere further — no PR flow was run, matching the previous session.

---

## What was fixed — eight commits

| Commit | Area | Defect (edge case) | Fix |
|---|---|---|---|
| `2cf8bcd` | learning loop | Lesson parser dropped three plausible writer styles: an `assert:` written as a markdown bullet/bold/blockquote didn't bind its test; a `## Watch — demoted from MUST-FIX` heading was gated as MUST-FIX because the words appeared anywhere in it; and milestone recurrence matched as a substring, so run **M1** was flagged "recurred" by any note mentioning **M10–M19**. | Widened `TEST_LINE_RE`; anchored `must_fix` to the *start* of the category name; whole-token milestone match with boundaries. |
| `60b82dd` | gate logic | **check 18 (retro-filed) was vacuous on every retry.** It keyed the retro by milestone, so a re-attempted (nogo/halted) milestone was satisfied by the *previous* run's retro while this run filed none — the exact "register never populated across nine retros" failure it exists to catch. **check 19 (consolidation) permanently forgave a missed window** (fired only at `docs % 5 == 0`, checked only the last window) and mis-counted same-run supersession docs. | check 18 now requires the retro to be fresh (mtime ≥ run-start), like check 11. check 19 counts distinct run numbers and inspects *every* complete window, failing on the earliest gap. |
| `e0ad44f` | **bootstrap** | The doctrine (TEMPLATE.md §1, the placeholders themselves) promises an agent fills `SPEC.md`/`MILESTONES.md` once before the first run — but `scope-guard` refused that write *never-escalatably*, so a fresh project could not be started by an agent at all. **This is the blocker you asked about.** | A content-gated exemption: while a contract still carries `<!-- ratchet:unwritten -->`, its corpus wall is lifted for that write. One-way (the marker's removal locks it forever; re-inserting the marker is itself a blocked corpus write), scoped to the two files by name, gated on the file's own state — not on any approval — so Tier 2b is not weakened. |
| `305c554` | metrics | `run_metrics.py --trend` crashed on a sidecar whose top-level JSON wasn't an object (a truncated write), and `SIDECAR_RE` capped run numbers at 3 digits so a 4-digit sidecar silently vanished. | Skip non-dict payloads; widen the regex to `\d{3,}`. |
| `ec369e8` | gate logic | A retro or `ACTIVE-LESSONS.md` at *exactly* its line cap failed the check while session-start's `head -n cap` injected it whole — `split("\n")` overcounts a newline-terminated file by one. | Added `line_count()` with `wc -l` / `head -n` semantics; both caps use it. |
| `de2d222` | **security** | On the case-insensitive Windows mount (your deployment) every path deny-rule was bypassable by flipping one letter's case: `.ENV` read a key, `.context/Spec.md` wrote the corpus, and `.claude/hooks/Guard.sh` **downgraded** from never-escalatable `control-set-write` to the human-confirmable `claude-dir-write` — letting an approval overwrite the guard that decides what approvals mean. | When `RT_WINPATH=1`, fold case in the deny/corpus matcher. Allow-side matchers (partition, manifest) stay case-sensitive on purpose. POSIX unchanged. |
| `26c1202` | security | `approve.sh` (human-only) was matched by a literal, case-sensitive substring, so `Approve.sh`, `appr*.sh`, and `approv[e].sh` reached it with the guard silent. | Detect by effect: case-folded substring, then glob-match each token carrying the `appr` stem against the real name — refuses wildcards that could expand to it without false-positiving on `apprentice.sh` or bare `*`. |
| `37ad24f` | gate logic | **check 3 (win-rows) accepted evidence on existence alone** — a 0-byte file, or one gitignored and never committed, greened the ship criterion though neither proves anything at HEAD. Both are producible with `touch`. | Require the evidence path to be a non-empty, git-tracked file. |

Every commit was verified with the full suite before it landed; no commit left the suite red. The
device-repo mechanics from the prior handoff still apply (`.claude` paths can't be committed
directly, so files went through a base64 tarball into `_transfer/`; git locks were swept into
`_to_delete/` before each operation — the mount still forbids `unlink`).

---

## What was found but NOT fixed — two, for your decision

These are real and reproduced, but each touches something I did not want to patch blind in a single
session. Proposed fixes are given so you can pick them up deliberately.

### A. Gate-closure expiry is a silent no-op on the unlink-impossible mount *(fail-open, high)*

`esc_expire_all` in `escalation-lib.sh` deletes approval/disclosure artifacts with `rm -f` and
returns success regardless of whether the file is gone. On your mount `rm` always fails, so at gate
closure a signed approval is **left on disk and still verifies** — single-use consumption has a
durable ledger backstop, but gate-closure expiry has none. Disclosures are worse: they're signed
with no TTL and die *only* by deletion, so on this mount one human disclosure of a red permanently
excludes that check from the ship exit code for the rest of the run epoch.

This is the same class as the harness's own `settled-ruling-needs-a-home` lesson, and it is squarely
on the real deployment. I left it unpatched because the fix touches the signing/verification core:
the right shape is a **durable "gate generation" counter** (a file, since writes succeed where
unlinks don't) that closure bumps, with `esc__approval_valid` / disclosure-verify refusing any
artifact from a superseded generation — plus making `esc_expire_all` verify each file is actually
gone and return non-zero so `gc-prune.sh`'s fallback runs and a human sees the failure. That belongs
on a Decision Card given it changes what "closed" means.

*Related, minor:* several `--selftest`s (scope-guard's especially) are not re-runnable on this mount
because their own `rm -f` cleanup fails, leaving scratch that fails the *next* run. They pass on a
first run and in any environment where `rm` works. Worth making the selftests self-clean via `mv` if
you want them green on repeated device runs.

### B. Write-target indirection bypasses the corpus/control/delete guards *(bypass, high)*

`rt_write_targets` in `hooklib.sh` collects a command's write targets only from tokens *after* the
verb, so any construct that separates verb from target defeats the corpus, control-set, and
`.claude` write/delete rules that route through it:

```
echo .context/SPEC.md          | xargs rm            → allowed (corpus deleted)
echo .claude/hooks/guard.sh    | xargs chmod 777     → allowed
cp /tmp/evil "$(echo .context/SPEC.md)"              → allowed ($()-hidden target)
```

The tell that this is the real root cause: `echo secrets/x | xargs rm` *is* blocked, because the
secrets rule scans **all** tokens while the corpus/control rules scan only the parsed write targets.
The proposed fix is to bring those rules up to the secrets rule's model — run the corpus/control/
`.claude`/forbidden deny lists against the full token set for delete/overwrite verbs — and to treat
`xargs` like the inline-interpreter rule already treats `bash -c`: a runner whose target is
unprovable, so refuse it when its child verb is a writer. I held off because `rt_write_targets` is
load-bearing for several rules at once and I'd want its own focused test pass before widening it.

*(Both A and B were also flagged by the enforcement-layer hunt as its findings #3 and #2.)*

---

## Lower-priority notes and hypotheses (not acted on)

- **`gc-prune.sh` fallback sweep may match nothing real** — its glob (`approved/* *.approval …`) does
  not match escalation-lib's actual artifact names, so in the degraded config where the library is
  absent it would report "0 removed" while leaving approvals live. Fail-open in exactly the
  configuration the fallback exists for. Unproven end-to-end (needs a signed fixture).
- **Consolidation INDEX rows have no legal shape** — the consolidated template mandates a row the
  frozen `INDEX_ROW_RE` cannot match; no enforced check reads them yet, so no harm today, but it's a
  "control-layer token nobody can read" waiting to recur.
- **Disclosures don't survive a halt→reopen** — a reopened run re-blocks previously human-disclosed
  reds. May be deliberate re-verification; flagged as a question, not a defect.

---

## Understanding notes (for the next session, and answering your questions)

- **`RATCHET_WEBHOOK_URL` is the harness's pager, not a Slack integration.** `notify.sh` POSTs a
  small hand-built JSON body (`{project, event, milestone, title, message, ts}`) over **HTTPS only**
  to whatever URL you set, and only for two classes — `escalation` (a Hard Stop / decision card
  waiting on a human) and `permission-stall`. Everything else is logged to
  `.pipeline/notifications.log` and dropped; it rate-limits so a stall pages once. A raw Slack
  incoming webhook expects `{"text": …}`, so to render nicely in Slack you'd point it at a reshaping
  hook (Slack Workflow, Zapier/Make, or a tiny relay) rather than the channel webhook directly.
  Prove the path with `bash .claude/hooks/notify.sh --test`.
- **The bootstrap flow now works the way you designed it.** With `e0ad44f`, a creator agent can fill
  the templated `SPEC.md`/`MILESTONES.md` at project start (the sanctioned pre-run drafting pass in
  `TEMPLATE.md` §0 — interview the human, then write), and the files lock to Tier 2b the moment the
  `ratchet:unwritten` marker is gone. Note the composition: the exemption opens only the corpus wall;
  the **manifest wall still stands during an active run**, so the drafting pass is only possible
  pre-run, which is exactly when the doctrine says it happens. The `spec-and-milestones-unfilled`
  row in `PENDING-HUMAN-ACTIONS.md` still frames this as a pure human action — its parenthetical
  ("no agent may write them") is now slightly stale and could be reconciled if you want the register
  to reflect the sanctioned agent pass.
- **The three OPEN install-filed rows are unchanged** — `branch-protection-missing`,
  `spec-and-milestones-unfilled`, `webhook-never-configured`. The harness is still installed inert
  until SPEC/MILESTONES carry real rows and (for unattended safety) the webhook is set.
- **Recurring bug class confirmed.** Every learning-loop defect here was a reader/writer drift — the
  parser reads one shape, the writer (a template or an agent) produces another. The harness names
  this as its own `reader-writer-drift` MUST-FIX lesson; it keeps recurring because a check that only
  ever sees a conforming payload is a green light wired to nothing. The new regression tests each
  drive the *mismatched* payload, which is the only thing that actually holds these fixes.

## Housekeeping

- `_to_delete/` (~3.8 MB) and the now-empty `_transfer/` are disposable scratch — git locks the mount
  couldn't unlink, and the base64 transfer artifacts from this session. Safe to delete both folders;
  I couldn't (`rm` is blocked on the mount and no delete-grant tool was available this session).
- `docs/audit-2026-08-22.md`, the prior handoff, and this file are all still untracked — commit them
  if you want the audit trail in history.
