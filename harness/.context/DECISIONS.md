# DECISIONS.md — Decision Log (hot file): {{PROJECT_NAME}}

**What this is.** The append-only log of decisions taken during runs. Every agent that meets an
ambiguity reads this file, so its length is a token cost paid once per agent per run, forever.

**Who owns it.** Shipped by the human; **appended to by the orchestrator** during a run. Rewriting or
reordering existing entries is a human action. Rollover is proposed by `retro`, never performed by an
agent.

**Header status.** `new ids are append-only; stubs are rewritable at rollover`.

---

## Rules — full text lives in `.claude/doctrine/CLAUDE.md` § "The decision log is two files"

That section is loaded into every session already (it is CLAUDE.md's own import chain, not an optional
read), so it is the one home for the hot/cold split, the caps (`DECISIONS_HOT_SOFT_LINES=250`,
`DECISIONS_HOT_HARD_LINES=300`), what must never go in this file, id/name rules, the entry template,
and rollover triggers. Restating them here duplicated ~55 lines read by every agent on every run for no
reader who didn't already have them — this file paid that cost and CLAUDE.md a second time, forever.
Fixed by the audit that also found the pattern in R1/R2 (a reader and a writer that drifted because two
copies existed to drift from). If the two ever disagree, CLAUDE.md wins and this note is the finding.

**One rule repeated here because getting it wrong corrupts the log, not just the prose:** every new
entry uses `## DEC-nnn · <name>` and the exact field order CLAUDE.md gives — copy the block from there
rather than the previous entry below, which may itself be a placeholder.

---

## Active defaults index

<!-- One line per currently-ACTIVE config default set by a decision. This is the section agents
     actually read at ambiguity time, so keep it to one line each and keep it current.
     Format: `key = value` — DEC-nnn · name -->

| Key | Value | Set by |
|---|---|---|
| <!-- none yet --> | | |

---

## Entries

## DEC-001 · ratchet-harness-adopted
**Date.** <!-- YYYY-MM-DD --> · **Status.** ACTIVE
**Decision.** {{PROJECT_NAME}} is delivered through the Ratchet harness: runs are scoped to one
milestone, gated by `{{VERIFY_CMD}}` at ship tier, and reach `{{BASE_BRANCH}}` only through a PR
carrying an affirmative Ship Prompt selection plus the tool-permission approval. The four-directory
ownership partition is binding: `.claude/` is agent-unwritable, `.context/` is human-owned Tier 2b,
`.pipeline/` is run-scoped agent scratch, `.agent-development/` is the never-pruned learning loop.
Stack pack `{{STACK_NAME}}` binds the command interface. Escalation runs in the mode set by
`ESCALATION_MODE`; the never-escalatable class is fixed and not extendable downward.
**Default/config.** `BASE_BRANCH = {{BASE_BRANCH}}` · `STACK_NAME = {{STACK_NAME}}`
**Affected.** —
**Simulated.** Simulated against 0 frozen rows; none changed (first decision of the project).
**Archive.** .context/archive/decisions/DEC-001-full.md (written at rollover)
