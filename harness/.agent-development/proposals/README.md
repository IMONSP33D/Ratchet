# `proposals/` — the supervisor-changeset pattern

**What this is.** The one sanctioned route by which a refinement reaches the **control layer**
(`.claude/**`) and the **governing corpus** (`.context/**`). Everything in this directory is a
proposal, a review of a proposal, or an apply note. **Nothing here is applied by the agent that wrote
it.** Owner: the human, who executes the final step.

## Why the pattern exists

Two facts collide.

1. The orchestrator and every seat are **barred from the control layer**. That is deliberate — an
   agent that can rewrite its own guardrails in response to being blocked by them has no guardrails.
2. Almost every expensive failure in the source corpus **was in the control layer**. Five of five runs
   died there, never in the engineering. So the party best positioned to diagnose the defect is
   structurally forbidden from fixing it, and its diagnosis has nowhere to go.

Filing that diagnosis as a retro row works for one-line changes. It fails for a coherent multi-file
change with an ordering constraint, because the retro table has no place to state "item 2 must land
before item 1 or nothing else can be *recorded*" — and that exact dependency was gotten wrong.

The pattern is the channel: **diagnose → audit → apply**, with a different party at each step.

## The three roles

| step | who | writes | must not |
|---|---|---|---|
| 1. **Changeset** | the orchestrator (barred from the control layer) | `SUPERVISOR-CHANGESET-NNN.md` — prioritised items, each with a site, a verified reproduction, an invariant, and its position in the landing order | apply anything; cite a line it did not re-read at the stated HEAD |
| 2. **Review** | an independent reviewer, fresh context | `NNN-<date>-changeset-review.md` — ordering, omission against the open registers, per-item merit, cross-run carryover | inherit the changeset's framing; skip the provenance caution below |
| 3. **Apply** | a human, or an apply agent under the human's approval | `APPLY-NNN.md` — what landed, how it was verified, and what is still owed | claim a verification it did not perform |

## Step 2's non-optional clause: the provenance caution

**The changeset is the run's account of itself, written by the party under review.** The reviewer
states this in its own words, at the top, before any item verdict — and then acts on it.

The measured basis: in the run that produced the source corpus's canonical changeset, **12 of that
run's own summary claims were falsified**. Its *artifact-checked* claims all held; its *summary* claims
did not. So the caution has a concrete instruction attached, not just a tone:

> Identify the claims of the shape that failed — re-derived tables, quoted regex results, any figure
> not read straight out of a retained artifact — and **name those as the items to re-verify
> independently before acting**. Everything whose truth depends on live state must say so.

The reviewer of the canonical changeset found the eleven items individually correct and **the priority
order wrong in three places**, including a dependency the changeset asserted was absent and its own
text contradicted three times. Order was the defect, not merit. A review that only grades items has
skipped the part that pays.

## Step 3: replica verification — three named drives

An apply agent verifies in an **isolated replica** before anything touches the repo. Three drives,
each of which caught something real:

1. **Frozen command corpus, additive-only.** Replay the project's frozen corpus of command strings
   (`guard-corpus.txt` or equivalent) through the changed rule and diff the verdicts. The canonical
   apply replayed **74 commands: 0 verdict changes, 0 loosened**, then a targeted probe of 16 strings
   producing exactly **6 `ALLOWED → BLOCKED`, 0 loosened**. Rule bodies were **extracted from the file,
   never retyped**, so the probe cannot drift from its subject.
2. **Mismatched-payload drive.** Drive every changed check with a payload requiring the **opposite**
   verdict. The canonical apply ran the fixed regex against the pre-fix document shape and reproduced
   the original failure (1 of 9 bound) before showing the fix bound 9 of 9. A check tested only on
   input it passes has not been tested. This is `reader-writer-drift`, and it is the drive most often
   skipped.
3. **Byte-identical re-apply.** Re-apply the patch to a pristine copy and assert the result is
   byte-identical to the tested files. A verification of a tree you cannot reproduce verifies nothing.

Plus the cheap ones, always: `bash -n` on every shell file, an AST parse on every Python file.

## The measured evidence the pattern works

`batched-refinements-self-harm` was **confirmed twice** — one batched retro-refinement commit broke a
closed milestone's WIN row and deleted the retro corpus; a second batch armed mid-run produced five
stacked channel defects. The standing rule from that is: scoped commits, suite between, stop at the
first red.

The canonical supervised changeset is the **first disconfirming evidence**: an eight-file
`.claude/hooks/` batch landed and drove control-layer postcondition trips **12 → 0**. That is the whole
argument for this directory. The batch was not the risk; the *unsupervised* batch was.

**It does not repeal the rule.** The changeset was still landed as separate commits with the suite
between them — one patch file so it reads as one diff, four commits so it lands as four. "Reviewable as
one, committable as one" is the conflation the pattern exists to prevent.

## The one caveat to close — say it as a step, not as a note

The canonical apply note contains this sentence:

> *"Verified in an isolated replica; the hook suite was NOT run, because this session cannot execute
> anything on the host. That verification is owed."*

That is honest and it is still a gap: an apply note whose "owed" section is prose gets read as a
completed apply. So the pattern makes the final verification a **named, checkable step with an owner**,
not a footnote.

Every `APPLY-*.md` ends with this block, filled in, and the entry is filed as a
`PENDING-HUMAN-ACTIONS.md` row until every line is checked:

```
## Host verification — HUMAN EXECUTES. Not complete until every line is checked.

| # | command | who | result | date |
|---|---|---|---|---|
| 1 | <FAST_TEST_CMD>  (the hook self-test)          | human |  |  |
| 2 | <VERIFY_CMD>     (the full deterministic gate) | human |  |  |
| 3 | python .claude/hooks/check_done.py             | human |  |  |
| 4 | re-drive the changed rules ON THE HOST with the mismatched payloads from the replica | human |  |  |

Status: NOT VERIFIED ON HOST
Pending action row: <name>
```

Line 4 is the one that is easy to drop and the one that matters: a replica proves the logic, the host
proves the *interpreter, the line endings and the shell* — and those are where a Windows/Git-Bash
deployment breaks. Until every row has a result and a date, the changeset is applied but not verified,
and the apply note must say `NOT VERIFIED ON HOST` in those words.

## When to use this, and when not to

**Use it** when a refinement touches `.claude/**` or `.context/**`, when it spans more than one file,
or when items have an ordering dependency between them.

**Do not use it** for a single-file, single-line refinement with no dependency — that is a
`PENDING-HUMAN-ACTIONS.md` row, and routing it through three roles costs more than the fix. A changeset
with one item is a register row wearing a hat.

**Never** use it to reach the never-escalatable set (CONTRACT §5.6). The control set —
`settings.json guard.sh scope-guard.sh hooklib.sh escalation-lib.sh approve.sh ratchet.config.sh` —
is edited by a human at a keyboard, reviewing bytes. A changeset may *propose* an edit to those files;
it may never be the thing that lands one.

## Naming

`SUPERVISOR-CHANGESET-NNN.md` · `NNN-YYYY-MM-DD-changeset-review.md` · `APPLY-NNN.md`, where `NNN` is
the run number that produced it. Standalone investigation notes take a CONTRACT §6 name matching their
finding or pending-action row, so the note and the row grep together.
