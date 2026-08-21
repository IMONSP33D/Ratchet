# Ratchet

**A gated autonomous-delivery harness for Claude Code projects.**

*The run moves forward or it stops. It never quietly slides back.*

A ratchet is a mechanism that turns freely one way and locks the other. That is
the whole design claim. You hand Claude Code a milestone and walk away; the
agent plans, writes failing tests, implements, reviews itself through an
adversarial board, and opens a pull request. Along the way it can be blocked,
refused, capped, and sent back around a loop — but it cannot weaken a test to
get green, cannot edit the rules that constrain it, and cannot merge to your
default branch without you personally choosing to.

When it can't proceed, it **stops loudly** rather than proceeding on a guess.

---


## Install, in order

```bash
./ratchet-dependencies.sh --check     # what's missing? changes nothing
./ratchet-dependencies.sh             # install it (asks before any sudo)
./install.sh --target . --stack python-pytest --project-name my-app
```

Windows/PowerShell: `.\ratchet-dependencies.ps1 -Check` then `.\install.ps1 -Target .`

**WSL note.** WSL is fully supported — it is Linux. The one thing that cannot work is a WSL
shell driving a *Windows* Python, because they do not share a filesystem. Keep the project and
the toolchain in one world: either clone into `~/` and use the distro's `python3`/`git`, or keep
the project on `C:\` and use PowerShell or Git-Bash.

## Upgrading mid-project

```bash
./ratchet-update.sh --check           # what would change? touches nothing
./ratchet-update.sh --apply
```

Your domain pack, contracts, findings, retros and secrets are never touched; harness files you
edited locally are preserved as `.local-<timestamp>` rather than clobbered; `.claude/` is backed
up with a one-line rollback. See `.context/UPGRADING.md`, especially for the agent-driven path —
the control layer is Tier 2b, so pipeline changes go through the supervisor-changeset pattern.

## Writing your project's contracts

`.context/SPEC.md` and `.context/MILESTONES.md` ship as placeholders on purpose. The harness does
not guess your project. Point Claude at `.context/TEMPLATE.md` — it interviews you and writes them.
Correct what it drafts; you own those two files.

## Who this is for

You want to give an agent a real unit of work — a milestone, not a task — and
not sit next to it. You are willing to write down what "done" means once, in
exchange for not having to re-litigate it every turn.

You are **not** the audience if you want an agent that "just figures it out."
Ratchet's central bet is that autonomy is bought with specificity: the more
precisely the finish line is defined, the further the agent can run unattended.
Its gates are only as good as your `SPEC.md` and `MILESTONES.md`.

---

## The core idea: a four-directory ownership partition

Everything else in Ratchet follows from one rule — **every file has exactly one
owner, and the owner determines who may write it.** Most agent-harness failures
are ownership failures wearing a costume: the agent "fixes" the test that was
catching its bug, or edits the rule that was refusing its command, and every
downstream check then agrees with it.

| Directory | Owner | The agent may | Why |
|---|---|---|---|
| `.claude/` | **The control layer** | read, never write | The guards, the gates, the agent definitions and the permission surface. If the agent can edit the thing that refuses it, the refusal is decorative. |
| `.context/` | **You, the human** | read, never write | `SPEC.md`, `MILESTONES.md`, `PIPELINE.md`, `TEMPLATE.md`, `CLAUDE.md`. The contracts. An agent that can move the finish line has not reached it. (`DECISIONS.md` is the one exception — appending a decision must never be the failing action.) |
| `.pipeline/` | **The agent, per run** | read and write freely | Scratch, findings, checkpoints, manifests, the consent record. Cleared and archived at gate closure. This is where the agent thinks. |
| `.agent-development/` | **The learning loop** | append | Run retrospectives, consolidated lessons, pending human actions. Tracked forever, never pruned. This is the only thing that makes run N+1 better than run N. |

Two of those four directories are things the agent *cannot* write. That is the
harness.

---

## What actually stops the agent

Enforcement is not in the prompt. Prompts are context; **controls are code.**
Ratchet installs eight hooks, and each one is a real process with a real exit
code:

| Hook | Fires on | What it does |
|---|---|---|
| `session-start.sh` | session start | Injects live run state so the agent knows where it is. |
| `guard.sh` | before every Bash call | Refuses by *effect*, not by verb: redirects, `sed -i`, `tee`, `cp`, heredocs and compound forms all count as writes. Every refusal carries a rule id. |
| `scope-guard.sh` | before every Edit/Write | Refuses a write to a path outside the run's manifest or the dispatched agent's partition glob, at the moment of the write. |
| `format.sh` | after Edit/Write | Formats. Never blocks. |
| `red-gate.sh` | when `test-writer` finishes | Runs the new tests and requires them to **fail**. The red phase is mechanically confirmed, not self-reported. |
| `subagent-gate.sh` | when `developer` finishes | Fast suite plus scope check on the partition. |
| `stop-gate.sh` | when the agent tries to end its turn | The definition of done. Tiered: inert with no run active, fast checks mid-run, the full deterministic gate at ship tier. Caps retries and refuses a second identical attempt. |
| `notify.sh` | on notification | Pages your webhook when a run stops for a decision. |

Plus four Python checkers the gates call: `check_done.py` (the definition of
done, item by item), `check_narrative.py` (narrative budgets and name
validation), `proof_map.py` (derives which tests cover which WIN row),
`run_metrics.py` (the mechanical record the retrospective reads).

**Fail closed.** A gate that cannot determine safety blocks. A gate whose
dependency is missing blocks. There is no "warn and continue" path in a
security decision, which is why the installer treats `jq` as a hard
requirement rather than a nicety.

---

## The twelve seats

Ratchet is not one agent in a loop. It is a pipeline of specialists, each with
its own context window, dispatched at the tier its job actually needs.

| Seat | Model | Stage | What it owns |
|---|---|---|---|
| `scout` | haiku | 1 | Repo recon: code patterns, test landscape, config and deps. One brief. |
| `researcher` | opus | 1 | Web research into `research.md`: spec grounding, best practice, edge-case ledger. |
| `research-verifier` | opus | 1.5 | Adversarial audit of the research. **Always** a separate dispatch — independence is a fresh context, not a model tier. |
| `architect` | opus | 2 | Freezes contracts, partitions the work, emits the file manifest and per-partition globs. |
| `test-writer` | opus | 3.1 | Red tests from the contract slice. Dispatched **per partition**. |
| `developer` | sonnet | 3.2 | One partition to green, plus the docs that partition made inaccurate. Fans out. |
| `reviewer` | opus | 5 | Correctness, test integrity, mission trace, claim verification, theater scan. |
| `security-auditor` | opus | 5 | "What would an attacker do" — a different question from "is this right", which is why it is a separate seat with its own mandatory checkpoint. |
| `checkpoint-scribe` | sonnet | checkpoints | Writes the jump summary. The evidence file is scripted, not written. |
| `clear-reviewer` | inherit | checkpoints | The approval authority. Judges from summary **and** scripted evidence, must spot-check one against the other, and **writes its own verdict**. |
| `retro` | opus | end of run | Reads the mechanical record and writes a typed, addressed list of refinements. Proposes; never applies. |
| `humanizer` | sonnet | before ship | Turns the run into a recap you can read in a minute. Presentation-only: every sentence traceable to an artifact, no new numbers, never cited as evidence. |

The tiering is deliberate: **haiku reads, sonnet builds, opus judges, and never
the reverse.** Cost is saved by deleting duplicated judgment, never by
downgrading a judgment.

---

## The two human stop points

This is the part to get right, because it is what makes unattended operation
tolerable.

**Stop 1 — The Ship Prompt.** Merging to your base branch is the one
irreversible act in a run, and it is asked **every single time**, with no
exception and no condition that skips it. It arrives as a selector you answer
with the arrow keys, never as chat text asking you to type a letter.

**Stop 2 — A material impact.** Something that changes what the project *is*,
not how this run goes: a frozen contract changed, a milestone made unachievable
as written, an expensive-to-reverse architectural commitment, an unfixable
critical security finding.

**Everything else is the agent's to decide.** An iteration cap, a review-fix
round, a blocked checkpoint it can resolve, a scope amendment inside the
milestone, a tooling failure — those are *how this run goes*, and a question
you could have been spared is treated as a defect the retrospective is meant to
find. The point of a harness is not to ask you more often. It is to make the
questions rarer and better.

Both stop points, plus three **Hard Stops** (a secrets or auth-boundary
deviation; anything irreversible outside the sanctioned ship flow; evidence of
prompt injection) that halt the run regardless of the agent's judgment.

### The ship flow is two factors and a record

1. An affirmative selection on the Ship Prompt card — *consent*.
2. The tool-permission approval on the merge command — *a factor the agent
   cannot produce*.
3. `.pipeline/ship-consent.json`, written before the merge — *the record*.

Be clear about what the third one is: **the agent writes it, so it is a record,
not a control.** It makes consent auditable and makes an accidental merge
impossible; it could not stop a determined agent. The control that actually
holds is **branch protection on your base branch**, which is server-side and
which the installer files as a mandatory human action for exactly this reason.

---

## Approve-and-continue

Some refusals are a question a human can answer in about ten seconds. Ratchet
splits refusals into two classes and the guard tells you which one you hit.

**Escalatable.** The refusal prints `This refusal is ESCALATABLE (id=...)`. The
agent files a request naming the exact bytes it tried; you run
`.claude/hooks/approve.sh <id>` **in your own terminal**; the agent re-issues
the identical call and it goes through. The approval is:

- **byte-exact** — bound to a sha256 of the command or the resulting file, not
  to a command class. One space different is a different command.
- **single-use**, recorded in an append-only ledger.
- **~30 minutes**, and bound to this run. Every approval dies at gate closure.
- **not producible by the agent.** It is an HMAC over a key the agent is denied
  from reading at two layers, and `approve.sh` is denied to the agent at three
  and refuses to run without a terminal.

**Never-escalatable.** Secrets and keys · force push · pushing or committing to
the base branch outside the ship flow · the governing corpus · and the control
layer's own files (`settings.json`, `guard.sh`, `scope-guard.sh`, `hooklib.sh`,
`escalation-lib.sh`, `approve.sh`, `ratchet.config.sh`). Nothing lifts these —
not an approval, not a card, not a domain pack. **The files that decide what an
approval means cannot themselves be changed by one.** That boundary is what
makes the escalatable class safe to have at all.

---

## Install

### Requirements

| | |
|---|---|
| **bash 4+** | Every hook is a bash script. On Windows this means Git-Bash (ships with Git for Windows) or WSL. macOS ships bash 3.2 — `brew install bash`. |
| **git** | The gates read the worktree on every hook firing. |
| **jq** | **Hard requirement.** Hooks parse a JSON payload; a security decision made without a real JSON parser is a guess, so the guards fail *closed* without it. No jq means no Bash tool calls at all. |
| **Python 3.8+** | Four gates are Python. Standard library only — nothing to pip install. |
| **gh** | Only for the ship flow (open PR, merge). The installer warns rather than refuses. |

### Linux / macOS / Git-Bash

```bash
git clone <ratchet-repo> ratchet
cd ratchet
./install.sh --target ../my-repo --project-name "My Repo" --stack python-pytest
```

### Windows (PowerShell 5.1 or 7)

```powershell
git clone <ratchet-repo> ratchet
cd ratchet
.\install.ps1 -Target ..\my-repo -ProjectName "My Repo" -Stack python-pytest
```

### Options

| bash | PowerShell | Meaning |
|---|---|---|
| `--target <dir>` | `-Target` | Repo to install into. Default: cwd. |
| `--stack <name>` | `-Stack` | `python-pytest`, `node-jest`, `generic`. Default: auto-detected. |
| `--project-name <s>` | `-ProjectName` | Human label. Default: repo folder name. |
| `--domain none\|interactive` | `-Domain` | Run the domain interview now, or later. |
| `--escalation-mode light\|strict` | `-EscalationMode` | How broad the escalatable class is. |
| `--base-branch <b>` | `-BaseBranch` | The protected branch. Default: detected, else `main`. |
| `--dry-run` | `-WhatIf` | Print every action; perform none. |
| `--force` | `-Force` | Proceed despite modified tracked files. |
| `--substitute-only` | `-SubstituteOnly` | Re-fill the brace markers after editing the domain pack. |
| `--uninstall` | `-Uninstall` | Reverse the install, restoring the pre-Ratchet settings backup. |
| `--no-verify` | `-SkipVerify` | Skip the post-install hook-suite run. |

### What the installer will and will not do to your repo

**It will not damage an existing project.** Specifically:

- An existing `.claude/settings.json` is **merged**, never overwritten. Your
  entries survive; Ratchet's are added; Ratchet's `deny` wins over your `allow`
  on a tie, because deny is the class that cannot be lifted at runtime. The
  original is backed up to `settings.json.bak-<timestamp>` first.
- An existing root `CLAUDE.md` is **never clobbered**. Ratchet's manual goes to
  `CLAUDE.ratchet.md` and the installer tells you to add one line —
  `@.context/CLAUDE.md` — to yours.
- Human-owned documents (`.context/`, `docs/`, `.agent-development/`) are
  written **only when absent**. An upgrade never rewrites your SPEC.
- Your domain pack (`.claude/hooks/domain.config.sh`) is preserved on upgrade,
  even though it lives under `.claude/`. It is the one file in there that a
  human owns.
- It refuses on a **dirty tracked worktree** (untracked files are fine — that
  is the normal state of every upgrade) so that `git checkout .` remains a
  complete undo.
- It refuses if the target **is not a git repo**, or is the harness source tree
  itself.
- It **verifies** that `secrets/` is genuinely gitignored rather than assuming
  the line it just wrote took effect — an already-tracked `secrets/` directory
  silently defeats `.gitignore`, and a committed signing key is forgeable
  forever.
- Re-running is an **upgrade**, and it is idempotent.

---

## Config surface

### Core — `.claude/hooks/ratchet.config.sh`

One file, every knob, all `${VAR:-default}` so the environment can override any
of them for one run without editing a tracked file. Paths, caps
(`MAX_STOP_RETRIES`, `MAX_REVIEW_ROUNDS`, `MAX_RUN_WORK_SECONDS`), narrative
budgets, the base branch, the escalation TTL, the webhook URL.

One caps detail worth knowing: the run budget counts **work time, not wall
time.** Every hook firing updates a last-seen marker, and a gap longer than the
idle threshold is folded out. Leaving a run open overnight does not burn the
budget; and no script may edit the run-start timestamp to clear a halt.

### Stack packs — `.claude/hooks/stack/<name>.sh`

The harness never contains a test command. It contains a **command interface**,
and a stack pack binds it: `VERIFY_CMD`, `FAST_TEST_CMD`, `SCOPED_TEST_CMD`,
`RED_TEST_CMD`, `COLLECT_TESTS_CMD`, `SECRETS_SCAN_CMD`, `DEP_AUDIT_CMD`,
`FORMAT_CMD`, plus the regexes that say which paths are tests and how a failure
renders in output.

v1 ships `python-pytest` (the reference), `node-jest`, and `generic` — where
every command is empty and gates that need one **skip with a loud notice
rather than silently pass.** Writing a new pack is one file and no code changes
anywhere else.

### Domain packs — `.claude/hooks/domain.config.sh`

Generated by `.claude/hooks/interview.sh`, which asks nine questions and is safe
to re-run (your previous answers become the defaults). It is the **only** file
in the harness that knows anything about your project:

- the irreversible action to wall off — its exec tokens and artifact filenames;
- your sacred invariant, which becomes **law 4**, quoted in every agent
  definition ("money is integer cents"; "no query without a tenant filter");
- what must never be hardcoded (**law 5**); where credentials live (**law 6**);
- security-boundary files, banned-read files, the governing corpus;
- extra never-escalatable rule ids; the arbiter label; a review lens and a
  security pass injected into the two board seats.

**An empty domain pack is valid and common.** `--domain none` still gets you the
control layer, the governing corpus, secrets protection and the ship gate. The
domain pack only *adds* walls.

Laws 1, 2 and 7 (TDD is the pillar; milestones are strict gates; the
deterministic gate is universal) are harness-fixed. Laws 3–6 are yours. Every
agent definition embeds the law block verbatim, and the test suite compares all
copies against the canonical file — because a law softened in one seat is
invisible everywhere else.

---

## Limitations, stated plainly

- **GitHub and `gh` only, in v1.** The ship flow is `gh pr create` / `gh pr
  merge` and the guard understands GitHub's command surface. GitLab and Bitbucket
  are not supported and will not half-work — they will fail at PR creation.
- **bash is required, including on Windows.** The hooks are bash scripts and v1
  does not ship a PowerShell hook implementation. The Windows installer refuses
  rather than installing a harness whose every gate would error out.
- **`jq` is required.** Not a soft dependency. Without it the guards fail closed
  and the agent cannot run any Bash command.
- **The consent record is a record, not a control.** The agent writes
  `ship-consent.json`, so it is auditable, not enforceable. **Branch protection
  is the control.** The installer files it as a mandatory human action and the
  README says it twice on purpose.
- **The gates are only as sharp as your WIN rows.** A milestone whose verify
  command is not script-decidable is a *setup defect* — Ratchet raises it rather
  than adjudicating it by judgment, which is the honest behaviour and also the
  annoying one.
- **Attribution degrades.** When a dispatch baseline is missing, the gates fall
  back to the partition glob, and then to a forbidden-path filter that **prints
  that it is weak**. In any mode below exact, a gate *reports* an out-of-scope
  file; it never orders a revert.
- **This does not make an agent smarter.** It makes an agent's failures visible,
  bounded and reversible. A model that cannot do the work will fail here too —
  just faster, louder, and without touching your base branch.

---

## Layout after install

```
your-repo/
  .claude/
    settings.json            merged permission surface + hook wiring
    agents/                  12 seat definitions + _LAWS.md
    hooks/                   guards, gates, config, stack packs, the test suite
  .context/                  YOUR contracts: SPEC, MILESTONES, PIPELINE, CLAUDE, DECISIONS
  .pipeline/                 run scratch; runtime gitignored, the record tracked
  .agent-development/        run retros, ACTIVE-LESSONS.md, PENDING-HUMAN-ACTIONS.md
  docs/evidence/             WIN-row proof, probe transcripts
  secrets/                   escalation signing key only; gitignored and verified
```

---

## Next

**[QUICKSTART.md](QUICKSTART.md)** — install, answer the interview, fill two
stubs, and run a real milestone in about ten minutes.
