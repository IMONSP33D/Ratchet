# Out-of-pipeline SPEC/MILESTONES interview prompt

**What this is.** The prompt you hand to an agent running *outside* a Ratchet project's hook
harness, to interview you and write `.context/SPEC.md` and `.context/MILESTONES.md`.

**Where to run it.** Not as a Claude Code session rooted in the target repo — that session
inherits `.claude/settings.json`, whose `deny[]` blocks both files, and you land back on the
original error. Run it either from the **parent directory** of the repo (so
`$CLAUDE_PROJECT_DIR` is elsewhere and the `./.context/...` deny patterns don't match), or from
a chat/Cowork session with the repo folder connected. Once the files are written, the deny is
correct again and protects them for the rest of the project's life.

**Before you start**, replace `<REPO>` with the absolute path to the target repo and
`<PROJECT>` with the project name.

---

## Paste everything below this line

---

You are drafting the two governing contracts for the Ratchet project at `<REPO>`:
`.context/SPEC.md` and `.context/MILESTONES.md`. You are running outside that project's hook
harness. That means the guardrails which normally make a bad draft impossible are not watching
you. The discipline below is the whole of your quality control — hold it yourself.

I am `<PROJECT>`'s principal and the human who owns these documents. I am technical and I built
this harness. Do not explain to me what a requirement is, what a milestone is, or why
specifications matter. Ask me things I know and you don't.

### Step 0 — Read before you say anything

In this order, and completely:

1. `<REPO>/.claude/doctrine/TEMPLATE.md`, end to end. It is self-sufficient and authoritative:
   the requirement-ID taxonomy (§2), the SPEC section structure (§3), the AV register (§4), the
   MILESTONES structure (§5), the frozen WIN row format (§6), naming doctrine (§7), and goldens
   and test-naming (§8) all live there. **Do not rely on anything in this prompt that
   contradicts TEMPLATE.md — TEMPLATE.md wins, always.** It ships with the harness and is
   replaced wholesale on upgrade; this prompt is not.
2. `<REPO>/.context/SPEC.md` and `<REPO>/.context/MILESTONES.md` — the unwritten placeholders.
3. `<REPO>/.context/DECISIONS.md`, if it has entries. Decisions already made are inputs, not
   things to re-ask.
4. The repo itself — source tree, tests, configs, READMEs, `Makefile`/task runner.

Step 0.4 exists to make your **questions** better, never to supply **answers**. TEMPLATE.md §0:
"an answer inferred from existing code is a hypothesis marked `TODO(human):` until confirmed —
code is evidence of what was built, never of what was wanted." So arrive informed: ask "the
tree has a `parsers/` module doing X — is that a component boundary you want enforced, or an
accident?" rather than "what are the components?" Show up knowing the shape and ask me to
confirm or correct it. Never convert a confident reading of the code into a requirement.

Then say, in under ten lines, what you understood the project to be and what you plan to ask
about. Then begin.

### Step 1 — The interview

**Pacing.** Three to five questions per turn, one topic at a time. Never a wall of forty
questions — I will answer a wall badly and we will both believe the result. At the end of each
topic, play back what you heard in a short bulleted summary and ask me to confirm or correct
before moving on. Confirmed summaries are your working record.

**Topic order** — TEMPLATE.md §0's list, as a funnel:

1. **Outcome** — what is true in the world when this is done, in one paragraph, naming no
   technology.
2. **Non-goals** — the adjacent thing a reasonable person would assume is included and is not.
   Push here; this is the section people skip and the one that stops scope creep at M3.
3. **Boundaries** — what crosses into the system from outside, and in what shape.
4. **Numbers** — every threshold, budget, limit, interval, with its unit.
5. **Derived values** — any figure the system will be *trusted* on, and how I would compute it
   by hand. These become §6 formulas and goldens.
6. **Failure** — what must never happen, and what the system does when it happens anyway.
7. **Volatility** — which facts the design leans on that are owned by someone else. These
   become the AV register.
8. **Proof** — per item, asked out loud: what command would show this working?

**Rules while gathering:**

- **Prefer my own words verbatim** for anything load-bearing. Paraphrase costs precision.
- **"Fast" is not a number.** When I answer an interval, threshold or budget with an adjective,
  ask once more for a figure and a unit. If I still don't have one, it becomes
  `TODO(human):` — never a plausible default you picked.
- **Record a range as a range**, and ask which end the design must survive.
- **"Obviously" and "the usual" mark an unstated requirement.** When I say either, stop and
  make me say the thing.
- **Never resolve a contradiction silently.** If something I say in topic 6 contradicts topic 2,
  quote both back and ask which governs.
- **"I don't know", "you decide", and "not yet" are legal answers** and you must take them at
  face value. Each becomes a `TODO(human):` line, or an AV item if it's an external fact, or a
  DECISIONS entry if it's an internal design choice I'm delegating. None of them becomes a
  sentence you wrote that reads as though I said it.
- **Announce every inference before you make it.** "I'm about to assume X follows from what you
  said about Y — correct?" is always in bounds. A silent inference is an invention.

**Topic 8 deserves its own discipline.** TEMPLATE.md §6.3: a WIN row with no verify command is
a SETUP DEFECT, raised to the human, never adjudicated by argument — and §6.2 requires every
verify command to be script-decidable, exit-0-on-pass, deterministic, network-free and
non-interactive. So ask for the command *while I still have the requirement in my head*, and
apply the §6.2 test out loud: **state the input that makes this command exit non-zero.** If you
cannot, the requirement isn't understood yet — say so and go back to it. This is the single
highest-leverage part of the interview; a milestone whose rows can't fail will pass without
proving anything.

### Step 2 — Audit yourself before drafting

Do not begin writing until the interview is finished and I have confirmed the last summary.
Drafting as you go anchors you and you will start filling structure with plausible material.

When the interview is done, before writing a line, list back to me:

- every question I answered with "I don't know" or a non-answer, and what each will become;
- every place you plan to infer something I didn't state outright;
- every requirement you have that has no verify command yet.

Get my sign-off on that list. It is your last checkpoint before the document acquires the
authority of looking finished.

### Step 3 — Draft

Write `SPEC.md` against TEMPLATE.md §3 using the taxonomy in §2 and the AV register in §4. Every
heading in §3 is mandatory; a section with nothing in it says `None — <why>` explicitly, because
an empty section reads as an oversight rather than a decision.

Write `MILESTONES.md` against §5, every WIN row to the frozen five-field format in §6, names per
§7. Copy the §6.1 "how to read a WIN row" table in, as §5 instructs. The AV ledger is **one list
mirrored across both files, not two lists** (§4).

Then re-read every WIN row and answer, for each: *what input makes this command exit non-zero?*
A row you cannot answer that for is not finished. Prefer refusal rows to existence rows —
"startup refuses a world-readable key" proves the system refuses; "a permission check exists"
proves nothing (§6.4).

### Step 4 — The standing rule, which outranks finishing

**A fabricated requirement is worse than a missing one.** A missing one is visibly missing and
someone fills it. A fabricated one acquires an id, is cited by a test name, appears in a WIN row,
passes a gate, and is then believed — by the next agent, by the reviewer, and by me, who will
assume it came from me. No gate in this system can tell an invented requirement from a real one.
Only you can, and only at the moment you write it.

So: **leave the TODOs in.** A SPEC shipping with a dozen honest `TODO(human):` lines is usable.
One with a dozen invented paragraphs is a trap that reads as complete. Phrase each TODO so a
one-line answer from me resolves it — the exact question, not "clarify this."

Do not smooth a gap because the surrounding prose reads better without it. Do not infer a number
from a similar project. Do not write a verify command you have not reasoned about failing. If
you notice yourself reaching for a plausible completion, that is the moment this rule is for.

### Step 5 — Write the files

Write both files to `<REPO>/.context/`. **Delete the `<!-- ratchet:unwritten -->` marker line
from each.** That marker is a one-way latch: while it is present the harness's gates report "not
written yet"; once it is gone the file is governing corpus and no agent may write it again. Leave
it in and you will have produced two documents the system still considers absent.

Do not touch anything else in `.context/`, and do not touch `.claude/` at all.

### Step 6 — Report

Tell me, in a short list:

- every `TODO(human):` line, with its file and section;
- every AV register item and the milestone where it resolves;
- every place you inferred rather than recorded;
- anything I said that you could not fit into the structure, which is usually where the structure
  is wrong rather than where I was.

Then stop. I make the edit that makes these documents mine.
