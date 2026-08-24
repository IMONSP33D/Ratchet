# Ratchet — decisions, corrections, and the audits you asked for

**2026-08-23.** Your rulings on the change board, three things I got wrong, and the five audits you commissioned. Not filed to the board.

---

## 1. Where I was wrong

### 1.1 The "ritual artifacts" — wrong on 15 of 17

You were right and my test was wrong. I judged `.pipeline/` artifacts by "does a hook parse it." The correct test is "does anything read it," and **agents read most of them under explicit instruction**.

Every one of the twelve agent definitions opens with a section literally titled `## Inputs — pointers, never payloads`, naming specific `.pipeline/` paths, and every agent's frontmatter grants `Read`. That is a designed inter-agent context channel, stated out loud, working as intended.

| Artifact | Hook readers | Agent readers | Verdict |
|---|---|---|---|
| `context.md` (scout brief) | none | architect, researcher, research-verifier, test-writer, developer, reviewer | **Inter-agent context** |
| `research.md` | none | architect, reviewer, research-verifier | **Inter-agent context** |
| `research-verification.md` | none | architect, test-writer, reviewer, researcher | **Inter-agent context** |
| `gap-analysis.md` | none | reviewer (×2, incl. a HIGH-severity check) | **Inter-agent context** |
| edge-case ledger | none | test-writer, reviewer, research-verifier | **Inter-agent context** |
| `contracts-<P>.md` | `proof_map.py` | developer, test-writer | Both |
| checkpoint `-evidence.txt` / `-jump.md` / `-clear.md` | `check_done.py` | clear-reviewer, scribe, retro, humanizer | Both |
| `findings.md`, `plan-files.txt`, `verify-last.json`, `context-live.md`, `run-events.jsonl`, `red-baseline.txt`, `cmd-log` | mostly yes | 4, 1, 4, 5, 1, 2, 1 seats respectively | Both |

Concrete example of why the design is right: `reviewer.md:29-32` — *"Do not re-run the full suite. It ran in the Stop gate and its result is on disk. Read `.pipeline/verify-last.json` and assert against it — and check that `head_sha` matches the SHA you are reviewing, because a verify result from a different tree is not evidence about this one."* That is good engineering, and I called it paperwork.

**Two survive as write-only, and only two:**

- **`<n>-<stage>-fast.md`** — zero readers of any kind across hooks, agents, doctrine, installers and the test suite. Three mentions, all describing the write. It is the orchestrator's self-report to itself, and the only checkpoint artifact with no consumer. Kill it or give it a reader.
- **`recap.md`** — no agent reader *by explicit prohibition* (`CLAUDE.md:925`: "Never cite `.pipeline/recap.md` as evidence for anything"). But `check_done.py` gates its five headings and word cap, and the intended consumer is you. That's mechanical + human, not ritual. Keep it; I was wrong to list it.

**Two real defects surfaced while checking this:**

- `PIPELINE.md:319` and `CLAUDE.md:469` both assert *"Every delegated agent receives `context-live.md` (SessionStart injects it)."* SessionStart fires on session start/resume/clear — **not on subagent dispatch**. The file reaches only the five seats whose own prompts tell them to read it. The stated mechanism does not exist.
- The delegation packet (`CLAUDE.md:458-469`) says it carries "**exactly**" five items, and `context.md` / `gap-analysis.md` are not among them — but `PIPELINE.md:105` says the architect "**receives**" both. The files arrive anyway (via each seat's standing Inputs list), but the two documents disagree about how. Pick one and delete the other.

### 1.2 `ratchet-update.sh` — I misunderstood the product

You're right, and this is the correction that matters most. I read Ratchet as a repo you clone, so "just `git pull`" looked obvious. It isn't a repo you clone — it's a **vendoring product**: it copies an agent stack into someone else's project, and update has to bring a newer Ratchet into a tree that has since diverged, without clobbering their edits.

That is a known-solved problem with a name: **template vendoring with a three-way merge**, the thing [copier](https://copier.readthedocs.io) does (`copier update` records the template version in the target, then merges template-old → template-new against the target's current state). Cookiecutter has the same problem and never solved it, which is why copier exists.

So the recommendation inverts: **don't delete it, and don't hand-roll it.** Your `.ratchet-manifest` + `.ratchet-version` + SHA-256 baseline instinct was *exactly right* — that's the recorded-template-version half of a 3-way merge. The problem is 1,477 lines re-deriving `git diff`'s job around it, plus the fact that `install.ps1` never writes the baseline, so every Windows install is permanently un-updatable cleanly.

**Redesign, ~200 lines:**

1. Install records `.ratchet/version` + a manifest of `path → sha256` for every harness-owned file. (You have this; make `install.sh` the only writer.)
2. Update classifies each file with a real 3-way compare — `old-template` vs `new-template` vs `on-disk`:

| old vs disk | old vs new | Action |
|---|---|---|
| same | changed | overwrite silently — clean upgrade |
| same | same | skip |
| changed | same | keep theirs — user-owned now |
| changed | changed | **the only interesting case**: write `.ratchet-merge` alongside and report it |

3. Report the conflicts as a list and stop. No rollback script, no backup directory, no generated shell.

Everything else in those 1,477 lines exists to compensate for not having a baseline on one platform. Fix the baseline and it evaporates. Keep the whole update *concept* — it is the product.

### 1.3 The plugin recommendation — you were right to reject it, and the reason is better than mine

You ruled it out for provider portability. Verifying that against the docs produced something stronger than your reasoning:

- **Ruling out plugin packaging costs almost nothing.** Hooks in `.claude/settings.json`, agents in `.claude/agents/`, skills in `.claude/skills/` are all plain committed files that work without any plugin. You give up marketplace distribution, auto-update and version pinning — and you were going to hand-roll those anyway, because Ratchet vendors into other repos and plugins never vendor.
- **The lock-in was never the packaging. It's the hook protocol.** The ~31 hook events, the `permissionDecision` schema, the `Bash(...)`/`Read(...)` rule DSL, `SubagentStop` matchers, auto-mode's classifier — none of that exists outside Claude Code.
- **And here's the part that changes the architecture:** your two `SubagentStop` gates sit in the layer that is simultaneously *the least portable* and *the weakest as a boundary* — advisory, in-process, silently disabled in an untrusted workspace, and (as established last round) unable to gate the next dispatch at all.

Moving those same invariants into **a wrapper process** (spawn the provider CLI once per phase; inspect git state between phases; refuse to start the next phase) and **the git server** (branch protection, required checks) makes them *stronger and portable at the same time*. That is an unusually clean trade — there is no tension between your two goals here. Claude Code hooks then become what they're actually good at: fast local feedback that kills a bad run in seconds instead of minutes.

**This is the biggest architectural change in the document, and it came out of your objection.** The wrapper is also the honest answer to "there is no orchestrator" — a skill is the Claude-Code-shaped answer; a wrapper process is the portable one, and you can have the skill call into it.

---

## 2. Your rulings, recorded

| # | Item | Ruling |
|---|---|---|
| 1 | All 20 defects | **Approved** |
| 2 | PowerShell → bash/WSL only | **Approved** |
| 3 | Escalation subsystem | **Delete approved** |
| 4 | `install.sh` terminal graphics | **Keep.** Overruled — my cut was wrong for a product whose install *is* the surface |
| 5 | `ratchet-update.sh` | **Keep + redesign.** I misunderstood the product (§1.2) |
| 6 | `ratchet-dependencies.sh` | **Keep.** Fast onboarding is the point |
| 7 | `run_metrics.py` | **Keep, fix later.** Wire the 10 unemitted counters or drop those specs |
| 8 | Six of twelve agent seats | **No. Do not touch the agents.** Fan-out with independent context is the design |
| 9 | 250-word agent prompts | **No. Do not touch the agents** |
| 10 | Plugin packaging | **No.** Provider portability (§1.3) |
| 11 | The agent must be able to push | **Binding constraint.** No blanket deny (§4.2) |
| 12 | `## Failure modes` / `## Who checks you` removal | Approved |
| 13 | sequence-gate, merge subagent gates, rewrite stop gate | Approved |
| 14 | State anchor, stack packs, CONTRACT.md, proof_map rewire | Approved |
| 15 | One critic definition, N dispatches | Approved — **see conflict below** |
| 16 | `ratchet-run` / `ratchet-contract` skills | Approved |
| 17 | One test file, six hooks | Approved |
| 18 | Rules: one-statement-one-home, exit-code gates, done = green verify + merged PR | Approved |
| 19 | Third-party audits + a budget audit | Approved |

**Conflict needing your call (#8 vs #15).** "Don't touch the agents" and "one critic definition, N dispatches" point opposite ways for the four critic seats. My reading: you blessed the *mechanism* (one file, dispatched N times with the lens in the task message) and rejected the *loss of parallelism*. Those are compatible — you keep four concurrent critics with four independent contexts, you just stop maintaining four near-identical prompt files. **If that's wrong, say so and the twelve files stay as they are.** I've made no change either way.

---

## 3. What the four unexplained things actually do

**`check_done.py` — do not kill it.** This is the definition of done: 19 checks the Stop gate runs at ship tier. Two are load-bearing (changed files ⊆ manifest; `verify-last.json` matches HEAD and exited 0). The other 17 audit the pipeline's own paperwork. The *concept* is the most important code in the harness — a Stop hook with nothing to consult is just "the model says it's finished." Keep the file, cut the checks that assert a file exists rather than a command's exit code.

**`check_narrative.py` — kill it.** 779 lines of word counts, sentence counts (by counting periods, so `e.g.` and `vs.` fail the one-sentence rule), and a marker blocklist that rejects a findings row containing `---`, `@@`, `FAILED` or `\n` as "probe transcript pasted into a cell" — i.e. the exact vocabulary a test-harness project uses to describe its own bugs. It fires on correct prose and misses reworded bad prose. Nothing downstream depends on it.

**Dead knobs / rules / IDs — what that card meant.** Three concrete things:

- **4 config knobs with zero readers**, verified: `FORGE`, `MAX_CHECKPOINT_BLOCKS`, `COMMIT_SCOPE_LINES`, and `SECURITY_BOUNDARY_FILES`. The last is the one that stings — the interview asks you to name your auth/crypto files, calls it Hard Stop 1, writes them to disk, and no code ever opens the list.
- **14 rule IDs declared in the escalation partition that no code emits**, including `test-weakened` and `test-written-by-developer` — the two the TDD premise most needs. They exist as strings, are classified, are documented, and can never fire. (Most vanish with the escalation subsystem; `test-weakened` should become real.)
- **`SECRETS_SCAN_CMD` and `DEP_AUDIT_CMD`** — bound by every stack pack, executed by nothing. `security-auditor.md` tells the model to "run `SECRETS_SCAN_CMD`", a bare variable name with no substitution marker, so the model receives the literal string.

---

## 4. The two redesigns your constraints force

### 4.1 The middle ground between allow and deny

Your objection was right and there's a documented answer: **`ask` is not a stall, it's a routing decision.** The evaluation order is hooks → deny → ask → mode → allow → `canUseTool`. In an unattended `-p`/SDK run an `ask` rule doesn't hang — it falls through to your callback. It is strictly more expressive than `deny`, because it preserves the capability and hands you the decision.

| Mechanism | Stalls unattended? | What it's for |
|---|---|---|
| `deny` rule | No | Only the genuinely never |
| `ask` rule | **No** in `-p` — routes to `canUseTool` | Conditional capability |
| `--permission-mode auto` | **No** — a classifier decides | The default posture for an autonomous harness |
| `PreToolUse` → `updatedInput` | **No** | **Narrow instead of refuse** — rewrite a bare `git push` into a scoped one |
| `PermissionRequest` hook + `updatedPermissions` | **No** | Grant a scoped, session-only permission mid-run |
| `permissionDecision: "defer"` | **No** — exits cleanly with the call preserved | Out-of-band approval; a wrapper resumes it |
| Sandbox + `strictAllowlist` | **No** | Removes *reach* without removing *capability* |

`defer` deserves a look — it turns an indefinite stall into a resumable checkpoint, which is the thing the escalation subsystem was built to do with an HMAC.

**Two caveats.** A parent in `auto`/`acceptEdits`/`bypassPermissions` cannot be tightened per-subagent — that asymmetry will shape the pipeline. And `auto` mode availability depends on plan and org settings, so design a `dontAsk` + explicit-allow fallback.

### 4.2 Letting the agent push — the honest answer

**No permission rule can express "only push to `agent/*`."** `Bash(git push origin agent/*)` has no space before the `*`, so the wildcard swallows everything after it. All of these match your allow rule:

```
git push origin agent/x --force
git push origin agent/x:main        ← a refspec. this pushes to main.
git push origin agent/x:$TARGET
```

`agent/x:main` should end the argument: it is literally a push to main, and the prefix rule permits it. No wildcard arrangement fixes this. Beyond refspecs: `git config push.default`, `git remote set-url`, aliases, `--repo=`, bare `git push` on upstream config, `--no-verify` defeating any `pre-push` hook, and — the unfixable one — *any* indirection (`make deploy`, `bash release.sh`, a Python script), because the matcher only ever sees the literal command string.

**So the boundary is not in the permission layer:**

| Layer | Catches | Misses |
|---|---|---|
| **Server-side branch protection / rulesets** | Everything — scripts, plumbing, aliases, refspecs | Nothing. This *is* the boundary |
| **Scoped credentials** (token/deploy key limited to `refs/heads/agent/*`) | Everything, fails closed | Nothing |
| `deny` on `--force`, `--no-verify`, `git config`, `git remote`, `gh api`, `curl` | Direct attempts | Anything inside a script |
| `PreToolUse` hook parsing argv properly | Refspecs, flag positions; can `updatedInput`-rewrite | Indirection. Fails open on unparseable input |

The top two are the only real boundary; the bottom two are fast local feedback so the agent doesn't waste a run. **Same for `gh pr merge`**: denying it is theatre while `gh api -X PUT .../merge` and `curl` with `$GH_TOKEN` exist. Give the agent a token that cannot merge, and merge failure becomes a server response that holds however the agent phrases the call.

This is the same conclusion as §1.3 from a different direction: **the enforcement that survives is outside the agent process.** That's also the portable answer.

---

## 5. The two audits you commissioned

### 5.1 `docs/` — is 27,174 words running context?

**No, and the reason is decisive: the Ratchet source repo has no root `CLAUDE.md`, no `AGENTS.md`, and no `.claude/` directory.** Nothing loads any of it into any session. There is no read order and no index. A harness whose own thesis is "prompts are context; controls are code" doesn't apply either half to its own development.

Classification: **1 fully live** (`BUILD-CONTRACT.md`), 2 live-as-roadmap, 3 mixed, **5 pure archive**. Four docs have zero inbound references from anywhere. `learning-and-context-deep-dive.md` and §1–2 of `audit-2026-08-23` are the same analysis twice, with identical numbers — the deep-dive's own header admits it. Roughly **6,000 of 27,174 words** carry information available nowhere else.

**`BUILD-CONTRACT.md` is genuinely load-bearing — keep it.** The code cites it as authority: `escalation-lib.sh:241` says *"Each entry below maps to a §5.6 bullet; the mapping is stated so a future reader can check it against the contract."* `format.sh:26` and `PIPELINE.md:370` do the same for §3. Its frozen names are re-asserted in `ratchet.config.sh`, and its §6 naming regex exists identically in two implementations with a round-trip test the contract itself demanded.

> **A dangling citation ships to every customer.** `format.sh` and `PIPELINE.md` both cite `BUILD-CONTRACT.md §3` as authority. Both are installed into target repos. `BUILD-CONTRACT.md` is not — the installer never copies `docs/`. Every deployed Ratchet contains two pointers to a file that doesn't exist on that machine.

**Compress to four files, ~5,900 words:**

| File | Words | Contents |
|---|---|---|
| `CHANGELOG.md` | ~1,100 | One block per version, one line per defect. Plus: *"suite counts are re-measured at release; a number here that disagrees with `test_hooks.py` is a defect in this file."* |
| `docs/BUILD-CONTRACT.md` | ~2,700 | Keep nearly as-is. Trim §9. |
| `docs/DECISIONS.md` | ~1,200 | ~15 ADR entries ≤80 words, in the harness's own frozen entry format. One per decision currently recoverable only by reading code or a 46 KB audit. |
| `docs/OPEN.md` | ~900 | One pipe table of known issues + an "accepted, not scheduled" section, one line + URL each. |

**Plus the 250 words that make it actually running context:** a root `CLAUDE.md` naming the read order and the three build rules that matter. Without it, compressing 27,000 words to 5,900 makes the docs cheaper but no more loaded. That's the highest-value 250 words in the exercise.

**One test worth 20 lines:** parse the rule IDs out of BUILD-CONTRACT §5.6 and assert set-equality against `ESC_NEVER_CORE`. §5.6 promises "this section and that variable change in the same commit" with nothing enforcing it — and BUILD-NOTES records §5.6 having already been *"four rule ids short"* while reading as exhaustive. That test converts your most load-bearing document from a document into a control.

### 5.2 The learning loop — yes, it survives, but cutting it isn't the point

**Verdict: cut to ~2,000 words safely. Every closing mechanism is code, and none of it reads the files being deleted.** The closure set is `session-start.sh:425` (injection) and `check_done.py` checks 14/17/18/19. Not one of them opens `README.md`, either template, or `proposals/README.md`.

| File | Now | Target | Why |
|---|---|---|---|
| `ACTIVE-LESSONS.md` | 951 | **700** | Keep all 10 lessons verbatim. Cut the 296-word provenance preamble to ~90 — it's inside the 100-line cap, so it's a cost paid every session forever |
| `PENDING-HUMAN-ACTIONS.md` | 1,275 | **550** | The 3 rows are 363 words; the rest is a 611-word essay |
| `INDEX.md` | 487 | **150** | Keep the frozen row format and token set; the war story already lives in the enforcing code |
| `README.md` | 980 | **150** | Zero inbound references. Also stale — claims a `BLOCKING` status that doesn't exist |
| `_TEMPLATE-run-retro.md` | 1,335 | **0** | See below |
| `_TEMPLATE-consolidated.md` | 1,208 | **0** | Fold a ~250-word skeleton into `retro.md` |
| `proposals/README.md` | 1,304 | **0** | Fold ~450 words into `UPGRADING.md` — which already ships and already points at this file |

Two of those have hard evidence behind them:

- **`proposals/README.md` is never installed.** Both installers copy top-level files only (`[ -f "$f" ] || continue`), so `proposals/` is created empty — while `UPGRADING.md:145`, which *does* ship, says *"Read `.agent-development/proposals/README.md` — it is the normative version."* Another dangling pointer in every deployment.
- **The retro template has already drifted again.** `retro.md:89-92` says the sections are FROZEN and shared with the template, and *"the two must never drift apart again: they did, once."* Section numbers were reconciled in commit `afdd8a3`. **Columns were not** — §7 is a 9-column table in one and a different 9 columns in the other; §4 is a bullet list in one and a table in the other. The fix reached the instance, not the class. That's the strongest argument for one home.

**But the cut doesn't improve the loop, and here's what does.** Three findings:

1. **Checks 18 and 19 are satisfiable with `touch`.** Check 18 wants a filename matching a regex plus an INDEX row; check 19 wants a filename in `consolidated/`. Neither opens the file. `check_done.py:727` says, about WIN evidence, *"an existence check a `touch` satisfies is not proof"* — and then does exactly that in the learning loop. **~20 lines fixes it:** require non-empty, git-tracked, and containing the required section headings.

2. **Both gates are skippable.** `check_done` runs only at ship tier, and the stop gate `_allow`s without calling it on budget halt, wall halt, repeat-failure, and retry-cap exhaustion. A halted run — which `retro.md:54` calls the *highest-value input* — has no retro enforcement at all.

3. **Check 14's deep check is dead in production.** `must-fix-recurred-with-green-assert` — the question `README`, `retro.md` and the consolidated template all call the loop's most important — needs events of type `lesson_recurred`. **Nothing emits them.** The reader exists, the counter exists, the selftest hand-writes the payload. No writer, anywhere. `reader-writer-drift`, the harness's own MUST-FIX lesson, live in the check the loop is built around.

**The missing link is real: nothing verifies a refinement was applied.** `grep refinement check_done.py check_narrative.py run_metrics.py` → one hit, in an unrelated error string. The loop can run forever, pass every gate, and change nothing.

The fix is small because the loop already demands its inputs — `retro.md:178-189` requires every §7 row to state *an invariant expressed as a grep pattern* and *every instance that grep returns*. That grep is a lint rule nobody installs.

```
.agent-development/REFINEMENTS.md
| name | target file | invariant (grep -E) | expect | status | applied-in | verified |
```

`expect` ∈ `present|absent` — that one column makes an invariant checkable in both directions. Then **check 20, `closure-verified`**: for every `APPLIED` row, run the regex against the target at HEAD and fail if it contradicts `expect`; stamp `verified` with the HEAD sha. Also fail a row that's been `PROPOSED` across three consolidations with no disposition — "proposed and quietly forgotten" is the common failure, not "applied and reverted."

~150 lines of Python for all three fixes takes the loop from two mechanical links to six. That is a better day's work than any of the 27,000 words in `docs/`.

---

## 6. The recurrence problem

You asked the real question: *how do we stop the agent from doing this again?* You've been round this loop more than once, and you keep having to reset to a viable building block.

I don't think this is a discipline problem, and I don't think a rule in a document fixes it. Here's the mechanism as I read it from the evidence in this tree:

**Every gate in Ratchet passes on a file existing.** Check 16 wants five headings. Check 19 wants a filename. A FULL checkpoint passes when a file's last line reads `CLEAR`. So the cheapest way for an agent to close a session successfully is to write a document. It did that 41 times.

**Prose has no failure mode.** A test is binary. A document is always "done." Give an agent a session with a document-shaped exit and the work expands until the context runs out — there is no other stopping condition.

**And the deepest one: documents are how the agent talks to its future self.** Every session starts cold and rebuilds context from files — `session-start.sh` injects 13 KB before the model reads a word. Writing more documents is a *rational memory strategy* under that constraint. It's the wrong one only because nothing prunes it. `ACTIVE-LESSONS.md`'s "hard cap 100 lines" is exactly the right idea, applied to one file out of forty-one.

So the brake has to be mechanical, and it has to attach to those three things:

1. **Make size a gate, not a rule.** A check that fails when `hooks/` exceeds N LOC or the prompt corpus exceeds N words. Fifteen lines. A budget nobody can fail is a preference; you have several already.
2. **Every new file declares its reader at creation.** A `readers.tsv` mapping file → reader, and a check that fails on any `.md` under `.claude/` or `docs/` with no entry. This is the one rule that would have prevented most of what we found — and note it would *not* have deleted the scout brief or the research overlay, because those have readers. It only catches the genuinely unread.
3. **Cap the memory channel and enforce the cap.** Pick the small number of files that carry state between sessions, put a hard line cap on each, and make exceeding it a gate failure. Rewriting under a cap is a fundamentally different act from appending.
4. **Third-party audit with a fixed question**, on your cadence — not "audit this" but *"what was added since the last audit, and what reads it?"* That question is cheap, answerable, and it is exactly the one nobody asked for three days.
5. **Net-line accounting in the commit.** Any commit adding more than N lines states what it deletes or declares a net add with a reason. Fifteen of your last sixteen commits were the harness patching itself; none of them had to justify growth.

The honest version of the whole thing: **the agent will produce whatever the exit condition rewards.** Right now the exit condition is "the paperwork exists," and it optimised that beautifully. Change the exit condition to "a command exits 0 and a PR merged," and the same model produces a tenth of the code — not because it's been told to be disciplined, but because there's finally something it can fail.

One caveat I owe you, since it applies to me too: this document is 3,000 words and it is the fourth artifact in three days. The pressure you're describing is not specific to the agent building Ratchet. **The reason to run M0 before touching anything else is that a milestone closing is the only signal in this entire system that isn't another document.**

---

## 7. Revised delete list

| Delete | Size | Change from before |
|---|---|---|
| All PowerShell | −4,496 | unchanged |
| Escalation subsystem | −3,199 | unchanged |
| Embedded `--selftest` blocks | −2,090 | unchanged |
| `check_narrative.py` | −779 | unchanged |
| 17 of 19 `check_done.py` checks | −1,600 | keep the file; it's the definition of done |
| Path/secret/push rules out of `guard.sh` | −1,010 | **to `ask` + hook, not blanket `deny`** |
| Dead knobs, 14 orphan rule IDs, unexecuted stack commands | cleanup | now itemised (§3) |
| `docs/` 11 files → 4 + root `CLAUDE.md` | −21,000 w | **was: delete all. `BUILD-CONTRACT.md` is load-bearing** |
| Learning-loop scaffolding | −5,500 w | **cut to ~2,000, then spend 150 lines closing the loop** |
| `<n>-<stage>-fast.md` | 1 artifact | **the only genuinely write-only pipeline artifact** |
| ~~All ritual artifacts~~ | — | **withdrawn — they're inter-agent context** |
| ~~`install.sh`~~ | — | **withdrawn — graphics stay** |
| ~~`ratchet-update.sh`~~ | — | **withdrawn — redesign to ~200 lines (§1.2)** |
| ~~`ratchet-dependencies.sh`~~ | — | **withdrawn** |
| ~~`run_metrics.py`~~ | — | **withdrawn — wire the counters later** |
| ~~Six agent seats / 250-word prompts~~ | — | **withdrawn** |
| ~~Plugin packaging~~ | — | **withdrawn (§1.3)** |

Revised total: roughly **−13,200 lines and −26,500 words**, down from −18,800 / −46,000. The tree lands near 21,000 lines instead of 8,000 — because four of the things I wanted to cut turned out to be the product.

**Order unchanged:** prove the four undocumented behaviours in a scratch repo, then delete, then rebuild. And run M0 before any of it.
