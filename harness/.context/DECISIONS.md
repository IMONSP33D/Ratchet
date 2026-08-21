# DECISIONS.md — Decision Log (hot file): {{PROJECT_NAME}}

**What this is.** The append-only log of decisions taken during runs. Every agent that meets an
ambiguity reads this file, so its length is a token cost paid once per agent per run, forever.

**Who owns it.** Shipped by the human; **appended to by the orchestrator** during a run. Rewriting or
reordering existing entries is a human action. Rollover is proposed by `retro`, never performed by an
agent.

**Header status.** `new ids are append-only; stubs are rewritable at rollover`.

---

## The hot/cold split

| | Hot file (this file) | Cold archive |
|---|---|---|
| Path | `.context/DECISIONS.md` | `.context/archive/decisions/DEC-nnn-full.md` |
| Holds | The template block below: the decision, stated so it can be checked | The full story — reasoning, alternatives, probe output, what it replaced |
| Caps | soft **250 lines**, hard **300 lines** | none; tracked and kept forever |
| Pruned | at rollover, to a one-line stub pointing at the archive | never |

**Appending a decision must never be the failing action.** Over the hard cap the checker emits
`ROLLOVER-REQUIRED` and the guard still permits the append. A harness that punishes you for recording
a decision teaches you not to record decisions.

**Rollover** triggers on: the hot file passing the soft cap · a milestone merging · a fifth-run
consolidation. It is `retro`'s step, proposed to the human — `.context/` is Tier 2b.

## What must never go in this file

Probe tables · pasted command output · review-board essays · WIN-row tables · anything longer than the
Decision field. Those belong in the archive body, `.agent-development/runs/`, `.pipeline/findings.md`,
or — when a human has to *do* something — `.agent-development/PENDING-HUMAN-ACTIONS.md`. A to-do
recorded as a decision is both a bloated log and a task nobody tracks.

## Ids and names

Every decision carries **both**: `DEC-nnn · <name>`. The number is the sort key and the archive
filename; the name is what humans read and cite. Names are kebab-case, 2–5 words, state the problem,
and are unique across findings, lessons, pending actions and decisions (`TEMPLATE.md` §7).

**Ids are permanent and never reused.** A decision that replaces an older one gets a NEW id and name
plus a `Supersedes.` line; the old id keeps resolving forever, because a citation that resolves to
nothing still reads as though it resolves.

## Entry template — use this and nothing else

```
## DEC-nnn · <name>
**Date.** YYYY-MM-DD · **Status.** ACTIVE | SUPERSEDED by DEC-mmm
**Decision.** <=120 words, stated so it can be checked.
**Default/config.** <key = value>                (omit if none)
**Supersedes.** DEC-nnn · <name>                 (omit if none)
**Affected.** REQ-… SEC-… AV-… WIN-…
**Simulated.** Simulated against <n> frozen rows; <k> changed meaning: <list>
**Archive.** .context/archive/decisions/DEC-nnn-full.md
```

**The `Simulated.` line is mandatory and is not a formality.** When a decision touches a frozen test
surface, a refusal rule, or a platform branch, enumerate the frozen rows it touches, replay each
against the ruling, and record the result. An entry without this line has not been adjudicated, only
asserted. `Simulated against <n>; none changed.` is a valid and common answer.

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
