# Ratchet — Quickstart

**Ten minutes from clone to a real gated run.** Six steps. Steps 3 and 4 are
the only ones that need you to think; everything else is typing.

If you have not read [README.md](README.md), you do not need to yet. Come back
to it after your first run, when the vocabulary means something.

---

## Step 1 — Install (2 minutes)

```bash
git clone <ratchet-repo> ratchet
cd ratchet
./install.sh --target ../my-repo --project-name "My Repo" --dry-run
```

Read the dry-run output. It prints every file it would touch and writes
nothing. When it looks right:

```bash
./install.sh --target ../my-repo --project-name "My Repo"
```

Windows: run the same two commands under Git-Bash (ships with Git for Windows) or WSL. There is no
separate PowerShell installer.

The installer checks the host **first** and refuses before writing anything if
a security-relevant tool is missing. If it refuses, the message names the tool
and the exact command to install it. `jq` is a hard requirement, not a nicety —
[see below](#3-jq-is-missing-and-nothing-works).

Then commit. The install is a diff like any other, and having it in a commit
means `git checkout .` stays a complete undo from here on:

```bash
cd ../my-repo
git add -A && git commit -m "chore: install Ratchet harness"
```

---

## Step 2 — Answer the interview (3 minutes)

```bash
.claude/hooks/interview.sh
```

Nine questions, all of which take Enter for the default, and all of which may be
left empty. It is safe to re-run — your previous answers become the defaults, so
changing one thing later costs one answer and a lot of Enter.

The three that are worth actually thinking about:

**Q2 — is there an irreversible or dangerous action to wall off?** Money moving,
a production deploy, `npm publish`, `terraform apply`, sending real mail,
deleting customer data. If yes, you give it two things: the **exec tokens** that
must never appear in a command (`--prod`, `deploy:production`), and the
**artifact filenames** that, by existing, would authorise it (`LIVE_CONFIRMED`).
Both become permanent walls — denied in `settings.json` *and* refused in
the guard, two layers, and no approval lifts either.

If the honest answer is no, say no. An empty domain pack is normal and you still
get the whole harness.

**Q3 — your sacred invariant.** This becomes **law 4** and is quoted verbatim in
every one of the twelve agent definitions. One sentence, stated so a reviewer
can catch a violation by reading a diff:

> "Money is integer cents; never float for prices, fees or P&L."
> "No query runs without an explicit tenant_id filter."
> "Every user-facing string goes through i18n; no literals in components."

**Q6 — security-boundary files.** Where your auth, signing, session or crypto
lives. Touching one is a Hard Stop: the run pauses **before** the edit, not
after it.

Then apply the answers to the doctrine documents:

```bash
../ratchet/install.sh --target . --substitute-only
```

Confirm nothing was left unfilled:

```bash
grep -rn "{{" .claude/agents .context | head
```

Zero output is what you want. A surviving brace marker in an agent definition
becomes literal text in a system prompt, where the model reads `{{VERIFY_CMD}}`
as a string instead of as your test command.

---

## Step 3 — Fill `SPEC.md` (2 minutes for the first pass)

Open `.context/SPEC.md`. It ships as an unwritten placeholder (`<!-- ratchet:unwritten -->`) —
there is nothing to trim, because nothing is guessed for you; every gate that reads it reports
"not written yet" until you write it. Read `.claude/doctrine/TEMPLATE.md` for the section shape
and the requirement-id taxonomy, or have Claude draft from it and interview you for the details —
that single pre-run drafting pass is the one case an agent may write this file, and its output is
handed to you to correct. **You do not have to finish it now.** For a first run you need three
things:

1. **Purpose, scope, non-goals** — one paragraph each. The non-goals paragraph is
   the one people skip and the one that stops scope creep three milestones later.
2. **Two or three real requirement ids.** Every requirement has a stable id
   (`REQ-`, `SEC-`, `TEST-`, `INV-`, `AV-`) that tests, commits and WIN rows cite
   forever. Start small and real:

   ```markdown
   - **REQ-CFG-01.** Configuration MUST be loaded from `config/default.toml`,
     overridable by environment variables prefixed `MYAPP_`. An unknown key MUST
     be rejected at load time with a non-zero exit, never ignored.
   - **REQ-CFG-02.** No endpoint, limit or coefficient MAY appear as a literal in
     source. Every such value resolves through the config loader.
   ```

3. Follow `TEMPLATE.md`'s section headings for the rest; leave a section as a stub with a
   `TODO(human)` marker rather than inventing content to fill it.

That is enough. `SPEC.md` grows one milestone at a time; a spec written in one
sitting is a spec written before you knew anything.

---

## Step 4 — Write a two-row M0 (2 minutes)

This is the step that decides whether your first run is a pleasure or a
disaster, and it is entirely mechanical.

Open `.context/MILESTONES.md`. It ships as an unwritten placeholder, same as `SPEC.md` — until
it is written the WIN-rows gate FAILS with that instruction rather than passing vacuously. Write
**two WIN rows for your first M0, not more.** Two is enough to see every gate fire, and short
enough that a failure is obvious rather than ambiguous.

```markdown
# M0 — Configuration spine

**Goal.** The project has a configuration loader that rejects unknown keys, and
`make verify` runs green on the tree.
**Entry.** Ratchet installed; `python3 .claude/hooks/test_hooks.py` passing.
**Run type.** Standard.

| WIN | Name | Requirements | Verify | Evidence |
|---|---|---|---|---|
| WIN-M0-01 | config-rejects-unknown-key | REQ-CFG-01 | `make win-m0-01` | `docs/evidence/M0/config-rejects-unknown-key.txt` |
| WIN-M0-02 | no-literal-for-config-value | REQ-CFG-02 | `make win-m0-02` | `docs/evidence/M0/no-literal-for-config-value.txt` |

**Exit gate.** Both rows green; PR merged.
```

And in your `Makefile`:

```makefile
win-m0-01:
	pytest tests/test_config.py -k unknown_key -q

win-m0-02:
	@! grep -rnE 'https?://|localhost:[0-9]+' src/ --include='*.py' \
	  || (echo "literal endpoint found in src/ - REQ-CFG-02" && exit 1)
```

### The three rules that make a WIN row work

**1. Write the verify command before you write the condition.** A condition you
cannot write a command for is a condition you do not yet understand, and it will
reach a run as a row nobody can adjudicate. Ratchet treats a row without a
script-decidable verify command as a **setup defect** — it raises it rather than
judging it by vibes, which is the correct behaviour and also the one that will
annoy you if you skipped this rule.

**2. State the condition so it can fail.** `WIN-M0-02` above is a grep row, and
grep rows are the best WIN rows there are precisely because they cannot be
argued with. Compare it to a row like "configuration is well designed", which
passes whenever the agent says so.

**3. Prefer "does the thing block" over "does the thing exist."** An *exists* row
is the most common way a milestone passes without proving anything. A CI config
that exists and a CI config that fails the build are different facts.

---

## Step 5 — Run it (1 minute of typing, then walk away)

```bash
cd my-repo
claude
```

Paste this, exactly:

```
Read .claude/doctrine/CLAUDE.md, .context/SPEC.md and .context/MILESTONES.md.
Confirm you understand the four-directory ownership partition and the two
human stop points, then run milestone M0.
```

If you would rather see the machinery before spending a real run on it, paste
this instead — it is the cheapest possible dress rehearsal:

```
Read .claude/doctrine/CLAUDE.md and .context/MILESTONES.md. Do not start a run.
Propose an M0 with exactly two WIN rows for this repo, write it into
.context/MILESTONES.md as a suggestion in your reply only, and stop.
```

Then go do something else. The run is genuinely unattended between the two stop
points. If it needs you, `notify.sh` pages your webhook — assuming you set
`RATCHET_WEBHOOK_URL`, which is one of the three actions the installer filed
into `.agent-development/PENDING-HUMAN-ACTIONS.md`.

---

## Step 6 — How to tell it worked

You will see **one selector** at the end, answered with the arrow keys:

```
Merge agent/m0-config-spine into main? (PR #1)
  > Yes - merge (Recommended)
    No - hold the PR open
    Escalate to <your arbiter label>
```

That prompt is the proof the harness ran. It is asked every run, with no
exception. If you never saw it, the run did not reach ship tier.

Then check the artifacts. Each of these is written by a different mechanism, so
if all five are right, the whole spine worked:

```bash
cat .pipeline/recap.md                    # 5 headings, under 400 words, readable
cat .pipeline/findings.md                 # every finding, severity as filed, disposition
ls  .pipeline/checkpoints/                # *-jump.md, *-evidence.txt, *-clear.md triples
cat docs/evidence/M0/proof-map.md         # every WIN row collecting at least one test
ls  .agent-development/runs/              # 001-M0-shipped.md or 001-M0-nogo.md
```

**Four specific things that mean it really worked**, as opposed to looking like
it did:

- **`.pipeline/checkpoints/` contains `-clear.md` files the reviewer wrote
  itself.** The orchestrator never transcribes a verdict. A `-clear.md` naming
  which claim it spot-checked, and what it found in the evidence file, is the
  independence working.
- **`proof-map.md` has a test under every WIN row.** A row collecting zero tests
  is a row that passed without proving anything, and the gate will have said so.
- **`.pipeline/verify-last.json` matches HEAD.** The deterministic gate ran once
  at ship tier and everything downstream read the artifact instead of re-running
  the suite.
- **`.agent-development/runs/001-*.md` ends with a table of typed refinements**,
  each naming an exact file to change. That is the learning loop; without it,
  run 2 repeats run 1's mistakes.

A **NO-GO** is a *successful* outcome, not a failure. It means a WIN row's verify
command actually ran, produced a result, and the result was negative — with raw
output under `docs/evidence/`. You still get a PR, a postmortem and the Ship
Prompt. "I could not get this green" is a different thing entirely and is not a
NO-GO.

---

## The three problems you will actually hit

### 1. The run stops on a refusal you think is wrong

**What you see.** The agent stops and reports a refusal with a rule id, and
and a line beginning `Do this instead:`.

**Fix.** Read that line — it is the way forward, and it is the whole point. Every refusal is final:
there is no approval to grant, no id to sign, nothing to unblock from your terminal. The agent is
expected to take the alternative and continue.

You can read any rule's guidance yourself without triggering the block:

```bash
.claude/hooks/guard.sh --explain <rule-id>
.claude/hooks/scope-guard.sh --explain <rule-id>
```

If the refusal carries **no** `Do this instead:` line, that is a defect in the harness rather than a
decision for you — the run has nowhere to go. Report it.

If the agent is blocked twice on the same intent, the wall and the plan disagree. That is worth your
attention: not to move the wall, but to decide whether the work was scoped to need something it
should not have.

---

## After the first run

Read `.agent-development/runs/001-*.md`. Its payload is not narrative — it is a
table of refinements, each naming the exact file to change, what to change, why,
the expected saving and the risk. It proposes; it never applies, because
`.claude/**` is not agent-writable.

Apply the ones you agree with. That is the loop: **the run is not over when the
PR opens, it is over when the retrospective is written** — and
`ACTIVE-LESSONS.md`, which every future run reads at start, is the only
retrospective artifact with a guaranteed consumer.

Then go fill in the next milestone. The specificity you invest in
`MILESTONES.md` converts directly into how far the agent gets before it needs
you.
