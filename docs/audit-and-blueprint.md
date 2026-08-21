# Pipeline Audit & Generic-Harness Blueprint

**Date:** 2026-08-20 · **Status:** PROPOSAL v2 — audit only, no changes applied. v2 incorporates two owner directives: humanized issue naming (§5.5) and a plain-language recap seat, the `humanizer` (§5.6).
**Audience:** the agent (or human+agent session) that will extract this pipeline into a reusable, project-agnostic harness/template for Claude Code projects.
**Sources:** full read of `.claude/` (settings + 22 hooks + 11 agent definitions + test_hooks.py), `.context/` (CLAUDE.md v2, PIPELINE.md, SPEC.md, MILESTONES.md, DECISIONS.md + archive), and `.agent-development/` (runs 001–009, consolidated 001-005, ACTIVE-LESSONS, PENDING-HUMAN-ACTIONS, proposals incl. SUPERVISOR-CHANGESET-008 and its review).

---

## 0. How to read this document

Section 1 is the verdict. Sections 2–4 are the audit (findings you must know about because a template inherits them). Section 5 is the extraction architecture. Findings in this document are referenced by **name**, not code — modeling the convention §5.5 requires the template to adopt. Where a finding traces to the kalshi corpus's historical ids (L-13, HA-045, H-09 …), those ids are kept in parentheses for grep-traceability into the existing retros. Section 6 is the template's document set. Section 7 is the installer and self-test spec. Section 8 is the lessons the run history proves should ship as defaults. Section 9 is the build order. Section 10 is open questions for the owner. Appendix A is the complete list of load-bearing artifact contracts the hooks parse — **the template breaks silently if any of these drift, so treat Appendix A as the extraction's frozen contract.**

---

## 1. Executive assessment

This pipeline is in unusually good shape for extraction, and the reason is structural, not cosmetic: it already separates *mechanism* from *project* better than most production CI systems.

**What nine runs prove.** The engineering loop converged: zero unfixed CRITICALs in `src/` across all nine runs, four merges landed, dispatch throughput grew 8→54 per run, and per-run friction dropped sharply where fixes landed (escalations 10→1, scope refusals 33→3, postcondition trips 12→0 between runs 008 and 009). The control layer did **not** converge the same way: every one of nine runs ended on a control-layer failure rather than an engineering one, and the human-action register grew to 46 rows. The template extraction is therefore not "package what exists" — it is "package the mechanism layer, and fix the five known structural defects on the way through, because a template mass-produces whatever defects it ships with."

**Why extraction is tractable.** Three properties make this harness genuinely portable:

1. `pipeline.config.sh` is already ~70% of a single point of configuration — every hook sources it; gate commands, branch policy, paths, caps, and budgets are already env-overridable variables.
2. The domain coupling (live-trading walls, Kalshi strings, money rules) is small and localized: essentially one `guard.sh` block, three never-escalatable rule ids, a few filename lists, and message wording. Thirteen of 22 hook files are near-generic today.
3. `test_hooks.py` (180+ tests, self-contained, no pytest needed) doubles as install verification, and it already contains the meta-invariant tests (`test_every_guard_rule_id_is_classified`, `TestDenyPartitionIsConsistent`, `TestLawsAreIdenticalEverywhere`) that make a botched extraction mechanically detectable.

**The core insight to preserve.** The four-directory ownership partition is the template's actual product: `.claude/` (control layer, agent-unwritable), `.context/` (human-owned contracts), `.pipeline/` (run-scoped agent scratch with a fixed schema), `.agent-development/` (the learning loop, never pruned). Everything else — the two-stop autonomy contract, Decision Cards, the escalation taxonomy, independent checkpointing, the retro loop — hangs off that partition. It is fully generic.

**The single deepest portability cliff** is the toolchain layer: `make verify` composition, pytest selectors, red-gate exit-code semantics, unittest output parsing in the postcondition checker, and `proof_map.py`'s `pytest --collect-only`. The recommendation (§5) is to put these behind a small command interface rather than abstract them fully, and ship Python/pytest as the first "stack pack."

---

## 2. Audit — control layer (hooks, guards, settings)

**Overall: sound, no CRITICAL findings.** The security-critical paths — never-escalatable enforcement at three layers, HMAC key unreachability, byte-exact binding, replay defense via append-only ledger, control-file double-denial — are each closed and each has a regression test. Adversarial traces attempted (redirect-into-protected-path, `cat`-as-write, consumed-approval replay, cross-run approval, one-byte-different command, `approve.sh` via cd-prefix, compound-git TOCTOU) all hit a wall with test coverage behind it.

### 2.1 Patterns to preserve verbatim in the template

- **Data-vs-structure command views** (`hl_strip_data` vs `hl_strip_msg`, hooklib.sh:131–221) — the correct solution to the "commit message is data" bypass class.
- **Decide-by-effect rule ordering** (guard.sh:350–465) — write-effects enumerated before read carve-outs (the HA-038 fix shape).
- **Two-factor escalation with byte-exact HMAC binding** (escalation-lib.sh) — MAC over `version|id|rule|tool|target_sha|run_token|expiry`, key read-by-path, single-use, TTL, run-bound.
- **Attribution degradation with loud weak-mode announcement** (hooklib.sh:313–354).
- **Fail-closed on setup and on missing jq** (guard.sh:20–34, scope-guard.sh:44–70).
- **Interpreter-by-probe** (`hl_pick_py`) — handles the Windows Store python-stub class; directly load-bearing for Windows hosts.
- **Single-source-of-truth via shell-out** — the Python checkers shell out to the shell libs rather than re-implementing rule sets; this is the anti-drift discipline the whole corpus is built on.
- **Null-not-zero metrics convention** (run_metrics.py) — "not instrumented" is distinguishable from "zero."
- **Session-start channel probe** — the control layer self-tests before it is needed.

### 2.2 Findings (fix before or during extraction — do not templatize defects)

| finding | sev | What it is | Disposition for the template |
|---|---|---|---|
| `hardcoded-project-name` | HIGH (for extraction) | `notify.sh:94` hardcodes `kalshi-crypto-bot` into the paging payload | Move to `PROJECT_NAME` in config. One line. |
| `dead-error-trap` | MEDIUM | `guard.sh:34` `trap … ERR` without `set -e` — suppressed inside `&&`/`if`, so the advertised fail-closed backstop is near-dead code (explicit `block` calls are what actually hold) | Remove or make real; do not ship a safety net that is documentation-only. |
| `fragile-consent-parse` | MEDIUM | Ship-consent parsing has a sed fallback when jq is absent (guard.sh:186–188) — regex-fragile on the one gate claimed to hold when other layers fail | Require jq at the merge gate; fail closed without it. |
| `no-file-locking` | MEDIUM | No `flock` on shared mutable state (retry counters, `run-idle`, `run-events.jsonl`, consumed ledger) — interleaving possible under parallel subagent stops | Add locking or document single-writer assumptions; fan-out is a template selling point, so this matters more in the template than here. |
| `check-that-cannot-fail` | LOW | `check_done.py` check #6 (edge-case-ledger coverage) never actually fails — parses but emits PASS/WARN only | Implement the set-difference or delete the check; a check that cannot fail is theater the corpus itself warns about. |
| `pruned-pending-escalations` | LOW | `gc_prune.sh:44` mtime-prunes pending escalation requests at 2×TTL — a slow human approval loses the justification sidecar (self-healing but lossy) | Prune consumed only, or exempt pending. |
| `bash-only-comm` | LOW | `esc_postcondition_check` uses `comm -23 <(…) <(…)` — bash-only process substitution with no fallback | Note as a bash≥4 requirement in the installer's host check. |
| `deny-partition-doctrine` | INFO | settings.json deliberately *allows* commands guard.sh then refuses (`git config`, `python -c`, …) so unattended runs stall on refusal-with-escalation-id instead of a permission prompt | Correct design; the template must ship this doctrine as documentation, or every deployer will read it as a misconfiguration. |

### 2.3 Claude Code feature dependencies to pin

The template must document minimum-version requirements for: hook events `PreToolUse`/`PostToolUse`/`SessionStart`/`SubagentStop` (with **agent-name matcher** — the least portable feature) /`Stop`/`Notification`; the `{"decision":"block"}` and `hookSpecificOutput.additionalContext` response protocols; exit-2-blocks convention; `$CLAUDE_PROJECT_DIR` injection; `stop_hook_active`; `AskUserQuestion`; and the permission precedence rule *deny beats ask beats allow and no hook overrides deny* — the entire deny-partition doctrine rests on that precedence staying stable.

---

## 3. Audit — doctrine and agent roster

**Overall: the 11 agent definitions are ~85% generic already and unusually high quality** — every seat states its mission, its output's parse shape, its failure mode, and who checks it. Model tiering is coherent (haiku recon / sonnet build+condense / opus judge / inherit for the checkpoint judge), and the three refused merges (security-auditor, research-verifier, scribe/judge) each carry an articulated independence rationale that the run history vindicates.

### 3.1 Findings

| finding | sev | What it is |
|---|---|---|
| `stale-pipeline-doc` | **HIGH — largest coherence defect in the corpus** | **PIPELINE.md is a v1-era document serving a v2 pipeline, and it is Tier-2b so no agent can fix it.** It names the retired roster (scout-code/tests/deps, code-reviewer, functionality-auditor, quality-gate, docs-writer, jump-reviewer, garbage-collector — ~8 of 11 seats stale), inverts the research-verifier independence rule ("do it YOURSELF if your session outranks opus" — the exact configuration the agent definition prohibits), lists a verdict (`NO-GO`) the clear-reviewer no longer emits, keeps the cap-exhaustion-escalates semantics v2 explicitly demoted, still mandates blocking a nonexistent filename CLAUDE.md v2 calls out as fixed, and lists 5 hooks where 23 exist. It is also the **only home** of several live things: run preconditions, the `gap-analysis.md` format, the FAST-checkpoint checklist, GC thresholds, soak mechanics. **Template consequence: regenerate PIPELINE.md from v2 reality — do not port it — and give the template a comparator so a mechanics doc can never rot against the manual again (the corpus applies "duplication needs a comparator" to the laws but never to its own doctrine docs).** |
| `verifier-edit-contradiction` | MEDIUM | `researcher.md` ↔ `research-verifier.md` contradiction: the researcher's commit rationale still describes verifier in-place edits; the verifier's own precondition and procedure steps retain in-place-edit voice while its output section mandates an overlay. This exact class already caused a tool-refusal-under-cap incident once; the fix reached one section, not the file. |
| `verifier-verdict-vocabulary` | LOW | Verifier verdict vocabulary split: `VERIFIED/REJECTED` (step 5) vs `CLEAR/BLOCK` (overlay template). Pick one; scripts and orchestrators grep for these. |
| `unchecked-manual-duplicate` | MEDIUM | Two byte-identical copies of the 824-line CLAUDE.md exist (`.claude/CLAUDE.md` and repo root) with **nothing comparing them** — identical today, drift accident pending by the corpus's own doctrine. Also: SPEC §4's canonical tree contradicts ACTIVE DEC-009 (governing docs moved to `.context/`). |
| `conventions-only-by-example` | MEDIUM (for the template goal) | SPEC/MILESTONES **structural conventions exist only by example**: the REQ/SEC/TEST/INV/AV taxonomy is one sentence; the AV lifecycle, verify-command validity rules, `make win-m{n}-{nn}` wrapper convention, goldens-become-unit-tests pattern, and the milestone Entry/WIN/Exit/Halt skeleton are nowhere written as reusable contracts. A deployer would reverse-engineer them from the Kalshi instance. The one exception — MILESTONES.md's "How to read a WIN row" header — is template-grade as-is. |
| `stale-readme-and-caps` | LOW | `.claude/README.md` references install inputs not in the tree ("Makefile.fragment from the v2 bundle", findings-template.md); CLAUDE.md's roster row for scout says "three sections" vs the definition's six; DECISIONS.md hot file is at 283 lines (over the 250 soft cap — one rollover due). |
| `doctrine-duplication-no-comparator` | MEDIUM (class) | Duplicated doctrine with no comparator, beyond the two findings above: checkpoint protocol told in 3 places, retired-roster table in 3, never-escalatable list in 3, one-home rule itself told 3 times. The laws' pattern (N copies + a mechanical comparator, emphasis-insensitive) is the fix shape; apply it or de-duplicate during extraction. |

### 3.2 The war-story problem

The doctrine's pedagogy is instance-specific (HA-007, L-16, the seven refusals, the DEC-036 saga) but the *rules* those stories justify are generic. Recommendation: the template keeps every rule, moves the stories into a **seeded ACTIVE-LESSONS ("run 000")** that ships with the template — so a fresh deployment starts with the lessons pre-learned and the manual stays lean. The corpus already invented this pattern; use it.

---

## 4. Audit — the improvement loop itself

**Diagnosis: exceptional. Repair: weak.** The retro→consolidate→ACTIVE-LESSONS loop measures rather than recalls (§2 script-generated, claims cite file:line, retros correct their own prior filings), hypotheses carry kill conditions and actually die (H-02 killed), and consolidation genuinely compresses (41 refinement rows → 14 by cause). But four measured failures must shape the template:

1. **`batch-fixes-break-things` (corpus H-09, confirmed ×3):** batch-applying refinements is self-harming — one batch broke a closed WIN row *and deleted the retro corpus*; a later bundle silently reverted a closed fix whose closure lived only in a commit message. First disconfirming evidence came only under the supervisor-changeset pattern (run 009: postcondition trips 12→0 after a supervised eight-file batch).
2. **`fix-reaches-instance-not-class` (corpus H-10, confirmed ×5):** fixes reach the cited instance, not the class — writer fixed but not reader, accumulator but not ceiling.
3. **The 009 meta-finding, the deepest unresolved defect:** seven MUST-FIX lessons recurred **with their binding `assert:` tests green** — asserts pin instances while lessons are invariants.
4. The INDEX register the outcome tokens feed was never populated across nine retros.

**Template consequence — ship these as loop rules, not advice:** refinements land in scoped commits with the suite between (anti-`batch-fixes-break-things`) unless supervised-changeset-reviewed; every refinement row states an invariant and enumerates all instances (anti-`fix-reaches-instance-not-class`); every MUST-FIX names a test that is driven with a mismatched payload requiring the opposite verdict (anti-`payload-never-reaches-subject`, corpus L-16); closures live in a greppable register, never only in git history; and consolidation asks the first-class question **"which MUST-FIX recurred with a green assert?"** — the question this pipeline's plateau traces to.

**The supervisor-changeset pattern is a keeper.** Orchestrator (barred from the control layer) writes a prioritized changeset → independent reviewer audits it *with an explicit provenance caution* → apply agent lands it with replica verification (frozen guard corpus, 0 verdict changes; mismatched-payload drives; byte-identical re-apply). The review measurably added value: reordered on dependency grounds, surfaced nine omitted register rows (three of them sequencing hazards on the changeset itself), rejected one fix as an instance of the defect class being fixed, and re-sorted items by approval channel — "a week of waiting into a day of work." Caveat to encode: the apply note admits final host-suite verification was never run; the template must make "human executes final verification" a named, checkable step.

### 4.1 Still-open items this repo should close (recommendations for *this* project, independent of the template)

Highest-leverage first; per the supervisor review, none of the exotic machinery is what blocks shipping — the mundane items are:

1. **Set `PIPELINE_WEBHOOK_URL`** (`webhook-never-configured`, corpus HA-005, open 5+ runs; three parks paged nobody) and **enable branch protection on `main`** (`branch-protection-missing`, corpus HA-006, open since 07-31 — it is the only merge control that actually enforces). Both are one-time human actions.
2. **Run the owed verification on supervisor-changeset-008** (the APPLY note says the host suite was never run). Until then L-11's effect-based guard fix is PATCHED-UNVERIFIED.
3. **Land the `gate-blames-wrong-actor` fix via disk, not env** (corpus L-13, refinement R-009-11): HA-045 measured that `PIPELINE_DISPATCH_ID`/`PIPELINE_PARTITION_GLOB` cannot reach hook environments from the Agent tool. Also apply the free half (R-007-12): degraded attribution *reports*, never orders a revert.
4. **Give the run lifecycle one origin file with a scripted writer/reopen/close** (`untrustworthy-run-budget`, corpus L-19 n=8 / L-23; run 009 halted on a number its own reopening manufactured).
5. **Regenerate PIPELINE.md** (`stale-pipeline-doc`) and fix the researcher/verifier contradiction (`verifier-edit-contradiction`, `verifier-verdict-vocabulary`) — both are cheap and both will otherwise be copied into the template.
6. **Do the DECISIONS rollover** (283 lines, over soft cap) with the already-landed scripted rollover.

---

## 5. Extraction architecture — three layers plus an interview

The template is **not** a parameterized copy of this repo. It is three layers with fixed seams:

### Layer 1 — Harness core (ship near-verbatim, ~85% of the value)

Everything that survived nine runs on its merits:

- The **four-directory ownership partition** and the `.pipeline/` data model (Appendix A).
- The **two-stop autonomy contract** (Ship Prompt + material-impact card), Decision Cards as AskUserQuestion selectors with mandatory recommendation + confidence + `Prior rulings:` paste + post-run card audit.
- The **escalation taxonomy**: two-class refusals (escalatable with id / never-escalatable wall), single-use run-bound approvals, the DISCLOSED state for human-settled reds (L-21's fix — a ruling gets a non-forgeable home on disk or the gate re-litigates it forever).
- **Independent checkpointing**: scripted evidence file + scribe summary + clear-reviewer that spot-checks and writes its own verdict. The run history shows this pair is the only path that audits the orchestrator's own record (11 falsified orchestrator claims caught across runs 007–008).
- The **findings ledger** with immutable severity-as-filed, the simulate-before-freeze rule, generated-not-written proof maps, `verify-last.json` never-recompute, one-home narrative rule with mechanical caps.
- The **retro loop** (templates, consolidation, ACTIVE-LESSONS, PENDING-HUMAN-ACTIONS ranked register, outcome-token re-measurement) plus the §4 loop rules above.
- The **supervisor-changeset pattern** as the sanctioned route for batch control-layer change.
- The **agent roster** (11 seats, plus the `humanizer` recap seat — §5.6) and the `_LAWS.md` mechanism: fixed laws + floor clause + emphasis-insensitive comparator test. Laws 1, 2, 7 are generic; laws 3–6 become **domain-pack slots** (see Layer 3) while keeping their shape: "the irreversible domain action is agent-unreachable," "the sacred domain invariant," "config not literals," "no secrets."
- Hooks: `hooklib.sh`, `pipeline-event.sh`, `dispatch-baseline.sh`, `checkpoint_evidence.sh`, `escalate.sh`/`approve.sh`/`escalation-lib.sh` (minus domain rule ids), `run_metrics.py`, `gc_prune.sh`, `session-start.sh`, `format.sh`, `check_narrative.py` — near-verbatim. `guard.sh`, `scope-guard.sh`, `check_done.py`, `stop-gate.sh` — same logic, literals hoisted into config lists.

### Layer 2 — Stack pack (v1 ships one: Python/pytest/uv/make)

Define a **command interface** — the only thing the harness core calls:

```
VERIFY_CMD          # full deterministic gate (this repo: make verify)
FAST_TEST_CMD       # scoped fast suite for subagent gates
SCOPED_TEST_CMD     # per-partition selector (this repo: make test-scope SCOPE=)
RED_TEST_CMD        # red-gate scope runner
COLLECT_TESTS_CMD   # test collector for proof maps (this repo: pytest --collect-only)
SECRETS_SCAN_CMD    # (gitleaks)
DEP_AUDIT_CMD       # (uv lock check / pip-audit)
FORMAT_CMD + FORMAT_EXTENSIONS
FAILURE_LINE_REGEX  # how a failing test renders in output (unittest FAIL:/ERROR: today)
TEST_SURFACE_REGEX  # what counts as a test-infra file (conftest.py|pytest.ini|… today)
```

Known stack couplings to route through this interface: `proof_map.py`'s pytest `::` node-id parsing; `esc_postcondition_failures`' unittest output parse; `check_done.py`'s TEST_SURFACE regex and `class <Name>` lesson-binding convention; `format.sh`'s extension list. **Do not fully abstract in v1** — ship the Python pack, document the interface, and let a second stack pack prove the seam.

**Forge:** standardize on **git + GitHub (`gh`) in v1** and document it as a requirement. The `gh`-verb allowlist, PR/merge consent flow, and branch-protection assumption are deeply structural; abstracting them is high-risk/low-payoff until someone actually needs GitLab.

### Layer 3 — Domain pack (generated by the init interview)

A `domain.config.sh` sourced after `pipeline.config.sh`, plus doc fragments:

```
PROJECT_NAME
FORBIDDEN_EXEC_TOKENS   # this repo: --live, KALSHI_ENV=live, KALSHI_LIVE_
FORBIDDEN_ARTIFACTS     # this repo: LIVE_CONFIRMED, HUMAN_APPROVAL.md
BANNED_READ_FILES       # superseded corpora that poison context
GOVERNING_CORPUS        # the human-owned doc set (SPEC/MILESTONES/PIPELINE/CLAUDE analogues)
SECRET_PATTERNS         # + exemptions (.env.example)
DOMAIN_NEVER_ESCALATABLE_RULE_IDS   # live-mode, live-artifacts here; empty is valid
SECURITY_BOUNDARY_FILES # Hard Stop 1 analogue (kalshi_auth.py here)
DOMAIN_REVIEW_LENSES    # reviewer lens slot (loop-budget here); security-auditor critical-path slot (money math here)
DOMAIN_LAWS             # laws 3–6 analogues
ARBITER_MODEL_NAME      # the "Escalate to Fable" slot
```

For a project with no dangerous "live" analogue, the lists are empty and the harness degrades cleanly to secrets + governing-corpus + control-layer protection — which is coherent. The meta-test `test_every_guard_rule_id_is_classified` already catches an unclassified domain rule automatically; keep it.

**The init interview** (a skill or guided first-session flow) asks: What is the irreversible action in this domain? What invariant is sacred (the integer-cents analogue)? What must never be hardcoded? Where do credentials live? What is the verify command / test framework / formatter? How many milestones, and which one is allowed to end the project (the NO-GO doctrine attaches there)? Does the domain have unattended validation windows (soak mechanics: include or omit)? Its output: the domain pack, the settings.json permission surface (generated from the stack tools, not copied from the kalshi instance), and the project-doc stubs.

### 5.5 Naming doctrine — humanized references (owner directive, 2026-08-20)

The kalshi instance references everything by opaque code: `L-13`, `HA-045`, `DEC-041`, `REV-M1-03`. The codes are permanent and greppable, but a human reading a card, a recap, or a register row learns nothing from them without a lookup. The template replaces codes with **named references**:

- **The agent that files an item names it**: a short kebab-case slug, ≤5 words, that states the problem — `gate-blames-wrong-actor`, not `L-13`; `hardcoded-project-name`, not `CL-1`; `dec-fee-bound-tightened`, not `DEC-041`. A name so generic it could apply to anything (`fix-issue`, `misc-problem`) is rejected by the narrative check the same way an empty rationale is.
- **Multi-step problems number their steps under one name**: `harness-adjustment-1`, `harness-adjustment-2`, … — one slug for the effort, a step counter for the parts, so a register row can say "blocked on `harness-adjustment-2`" and a human knows both what and where.
- **The permanence guarantees do not weaken.** Names are permanent, never reused, never renamed — a superseding item gets a *new* name and a `Supersedes:` line, exactly as DEC ids work today. Uniqueness is enforced mechanically (the register check greps for collisions at filing time).
- **Parser impact — treat this as a reader-writer change.** Appendix A contracts 3 (DEC id format), 4 (findings ledger id column), 6 (amendment lines `<path> <id>`), and 14 (lesson ids and `assert:` bindings) all parse id *shapes* (`DEC-\d+`, `L-\d+`, `WIN-M\d+-\d+`). Every parser and its writer change together, with round-trip tests driven by mismatched payloads — this change is itself an instance of the `payload-never-reaches-subject` / `reader-writer-drift` class, and botching it reproduces that lesson inside the template's first release. WIN rows may keep their positional ids (`WIN-M1-03` is a coordinate, not a description) but each row gains a name column.
- **Historical corpus ids stay as they are.** The kalshi retros are an archive; this document cites their ids in parentheses so evidence stays greppable. The seeded run-000 ACTIVE-LESSONS ships with named lessons that carry their original corpus ids as a provenance footnote.

### 5.6 New seat: the `humanizer` (owner directive, 2026-08-20)

A twelfth roster seat, added at the recap. Every run currently ends in artifacts written for the machine and the board — ship report, findings ledger, retro. The one document written *for the human who has to decide things* doesn't exist. The `humanizer` fixes that.

| Property | Spec |
|---|---|
| Model | sonnet — this is faithful condensation, which is sonnet's defined job in the model doctrine; it makes no judgments |
| When | End of every run, **after the retro, before the Ship Prompt** — so the human reads it right before answering the merge card, and it exists even on halted/NO-GO runs |
| Inputs (pointers, not payloads) | ship report / postmortem, run-journal, findings ledger, the milestone map, the retro, PENDING-HUMAN-ACTIONS |
| Output | `.pipeline/recap.md`, also posted to the human as the run's closing message |

**The five fixed sections** (≤400 words total, high-school reading level; technical terms allowed but each gets a one-line plain gloss):

1. **What got done** — in plain terms, what was built or decided this run.
2. **Where the project stands** — which milestone we're in, what's now proven that wasn't before.
3. **What's next** — the next milestone or the next human action, in one or two sentences.
4. **Issues you should know about** — open findings and pending human actions, by their §5.5 names, each explained in a sentence a non-specialist can act on ("`webhook-never-configured`: the pager that's supposed to alert you has never been set up — one env variable fixes it").
5. **How close to launch** — a grounded estimate: milestones closed / total, what stands between here and done, and whether this run moved that number.

**Guardrails, or this seat becomes a liability:** it is **presentation-only** — every sentence must be traceable to an artifact on disk, and it may not introduce claims, numbers, or optimism absent from the record (the `unaudited-self-account` lesson, corpus L-18, with its 29 uncaught instances, is exactly the failure mode a friendly summarizer amplifies). It is never a decision channel, never a substitute for the ship report, and the Ship Prompt's card never cites it as evidence. The clear-reviewer does not gate it (it sits downstream of every verdict), and the scribe/judge separation is untouched. Cost: one sonnet dispatch per run, pointers only.

---

## 6. Template document set

**Harness-owned, ship near-verbatim** (after noun-extraction and the §2–3 fixes): all Layer-1 hooks and tests; the 11 agent definitions (fix `verifier-edit-contradiction` and `verifier-verdict-vocabulary` first) plus the new `humanizer` definition (§5.6); `_LAWS.md` mechanism; a **rewritten-with-slots CLAUDE.md** — its harness sections (two-stop contract, cards, escalation/approve/disclose, Ship Prompt two-factor + consent record, checkpoints, verdicts, findings adjudication, token/model doctrine, risk-tier shape, ambiguity protocol, DEC-log split, retro loop, definition of done, hard rules) are ~80% generic in content but 0% in any single section, so it needs a rewrite with substitution slots, not a sed pass; a **regenerated PIPELINE.md** written from v2 reality (per `stale-pipeline-doc` there is currently no accurate stage-mechanics doc to copy) — and give it a comparator or merge it into CLAUDE.md.

**Per-project stubs the deployer fills:** SPEC-equivalent with mandatory skeleton headings (requirement-ID taxonomy declaration, AV/volatile-facts register, goldens-as-tests, config-keys, testing requirements, security requirements); MILESTONES-equivalent keeping the "How to read a WIN row" header verbatim plus the Goal/Entry/WIN-table/Exit/Halt skeleton; DECISIONS.md shipped as header + entry template + empty defaults index; optional NON-NORMATIVE RESEARCH.md.

**Written as new reusable contracts (fixing `conventions-only-by-example`):** a `CONVENTIONS.md` that states, as normative text, everything currently learnable only by example — WIN-row validity rules, verify-command requirements, the AV lifecycle (`open → measured → configured`), the wrapper-target convention, evidence-path layout.

**Seeded learning loop:** ACTIVE-LESSONS "run 000" carrying the generic lessons of §8 with their original evidence citations; empty runs/, consolidated/, metrics/; PENDING-HUMAN-ACTIONS with the install checklist pre-filed as its first rows (webhook, branch protection, key generation — the exact items this project left open for five runs).

---

## 7. Installer and self-test

**Installer must:** chmod +x all hooks; generate `secrets/escalation.key` via `approve.sh --init-key` and **verify** (not just warn) that `secrets/` is gitignored; write the ignore/track partition for `.pipeline/` runtime files (the correct partition is already encoded in `test_hooks.py` — reuse it as an installer assertion); **merge, never overwrite,** an existing settings.json; scaffold `.pipeline/` and `.agent-development/{runs,consolidated,metrics}`; record the postcondition baseline (`approve.sh --postcondition-baseline`) so a host with pre-existing failures has a floor; run the host check (bash ≥4, jq required, git, gh, the stack-pack tools, Claude Code minimum version per §2.3, and on Windows: the interpreter probe, UTF-8 stdout reconfigure, CRLF handling); then **run `test_hooks.py` as install verification** — green means the control layer is operational on this host. Note both `install.sh` and `install.ps1` already exist in the project docs as starting points.

**Self-test doctrine:** `test_hooks.py` ships as the harness's acceptance suite, with one change — the handful of tests embedding kalshi tokens as test data must draw them from the domain pack, so the suite tests the *configured* forbidden tokens. The meta-invariant tests (rule-classification completeness, deny-partition consistency, laws comparator) are what make future harness upgrades safe; they are non-optional.

**Distribution form:** two viable shapes — (a) a template repo + installer, or (b) a **Claude Code plugin** (hooks + agents + skills + the init-interview skill packaged together). The plugin form fits the artifact best (agents and hooks are exactly what plugins bundle) and makes upgrades a plugin-version bump; the template-repo form is simpler and keeps everything inspectable in-tree. See open question Q3.

---

## 8. Ten lessons the run history proves — bake in as template defaults

Each is generic (would recur in any Claude Code project), evidenced, and priced:

1. **`budget-work-not-wall-clock`** — the run lifecycle has exactly one origin file with scripted write/reopen/close (corpus L-19 n=8, L-23 — five run-ends at 211–3472% of cap while real work never exceeded ~50%).
2. **`gate-blames-wrong-actor`** — a gate attributes to an actor only what that actor wrote, and in degraded mode it reports, never orders remediation (corpus L-13 n=9 — agents ordered to revert Tier-2b files and untracked files with no version to revert to; 31+ correct refusals burned as tokens). Pair with **`shared-git-index`**: per-dispatch worktrees or orchestrator-only commits (HA-040 — parallel agents staged each other's half-written work, twice, silently).
3. **`rulings-need-a-home-on-disk`** — every human ruling gets a non-forgeable record (corpus L-21 — 10 gate blocks in 3h19m re-litigating settled reds until DISCLOSED existed).
4. **`control-layer-is-an-availability-surface`** — before it is a security surface: probe it at session start; anything agent-unrepairable has MTTR = human availability (corpus L-03 n=9, L-20 — an approval channel that had never once worked, discovered mid-run, five defects each hiding the next).
5. **`decide-by-effect-not-verb`** — guards judge the effect on the protected path, never the verb token (corpus L-11 n=7 — `cat x > LIVE_CONFIRMED` was ALLOWED; two CRITICALs).
6. **`reader-writer-drift`** — reader and writer of every state file change together, proven by round-trip; every check is driven with a mismatched payload requiring the opposite verdict (corpus L-16 n=8, H-10 ×5 — a reporter published idle≈56M years for five runs; a MUST-FIX check false-FAILed for two windows).
7. **`independent-verdict-writer`** — reads scripted evidence it did not choose and authors its own verdict (corpus L-04 — the single most load-bearing control; caught the orchestrator poisoning the context injected into every downstream seat).
8. **`unaudited-self-account`** — the run's story about itself is the artifact no gate checks, so counters come from hooks the counted party cannot skip, and numeric ship-report claims gate against artifact paths (corpus L-18: 29 partial-summary instances, 0 self-caught; `dispatches_total=0` beside 32 real dispatches for four runs).
9. **`artifacts-outlive-their-run`** — per-run scoping of every artifact and counter; nothing survives silently (corpus L-22 — a prior run's CLEAR counted in this run's verdict slot).
10. **`registers-over-prose`** — anything that must be found later lives in a register, and appending a decision can never be the failing action (corpus HA-034 — the run couldn't record its own decisions three times in one run; a closed fix was reverted because its closure lived only in a commit message).

Second-tier defaults worth shipping: delegation packets open with a one-sentence GOAL the returned conclusion is checked against; never write speculative artifacts into the repo tree; generate evidence rather than hand-maintain a second copy of any answer; right-size approval friction — the byte-exact HMAC ceremony measured net-negative for routine `.claude/` writes and was replaced by a confirmation card (DEC-046) while keeping a small never-liftable wall; the correct template default is the two-class refusal taxonomy with **few** rules in the never class.

---

## 9. Suggested build order for the extraction agent

Each phase ends with `test_hooks.py` green; control-layer changes land one scoped commit at a time or under a supervisor-changeset (§4 rules apply to the extraction itself).

1. **Fix in place** (this repo): the six control-layer findings (`hardcoded-project-name` through `pruned-pending-escalations`) and the two verifier contradictions; verify supervisor-008 (owed). Small, and everything after copies these files.
2. **Hoist literals**: create `domain.config.sh`; rewrite guard.sh/scope-guard.sh/hooklib.sh literal blocks to iterate config lists; move domain rule ids out of `ESC_NEVER`; point the token-embedding tests at the domain pack. The Tier-2b tests are the safety net — they must stay green with the kalshi domain pack loaded and pass meaningfully with an empty one.
3. **Define the stack interface** (§5 Layer 2) and route the five known couplings through it; ship the Python pack as the reference implementation.
4. **Regenerate PIPELINE.md** from v2 reality; add a doctrine comparator (or fold it into CLAUDE.md); write `CONVENTIONS.md` (DR-5).
5. **Rewrite CLAUDE.md with slots**; extract war stories into the seeded run-000 ACTIVE-LESSONS.
6. **Templatize settings.json** as generated-from-config, with the deny-partition doctrine documented beside it.
7. **Build the installer + host check + init-interview skill** (§7); reuse `install.sh`/`install.ps1` as bases.
8. **Prove the seam**: deploy the template into a trivially different scratch project (different domain, same Python stack), run the install verification, then run one small end-to-end milestone. The template is done when a fresh project's first run ends on the merits — not on the control layer.
9. **Port the loop rules** (§4) into the retro/consolidation templates, including the "recurred with green assert" consolidation question; apply the §5.5 naming doctrine across all registers/parsers as one reader-writer changeset with round-trip tests; add the `humanizer` seat and its recap contract (Appendix A.18) to the definition of done.
10. Optionally: package as a plugin (Q3).

Rough effort: phases 1–2 are S–M; 3–5 are M; 6–7 M; 8 is the real test and is M–L.

---

## 10. Open questions for the owner (Sam)

1. **Stack scope for v1** — Python/pytest only (recommended: ship the command interface but only one pack), or do you have a concrete second stack (Node? something else) that should drive the interface design now?
2. **Forge scope** — is GitHub-only acceptable for v1? (Recommended yes; the gh/branch-protection coupling is deep.)
3. **Distribution form** — template repo + installer, or Claude Code plugin? (Plugin fits the artifact; repo is simpler to inspect and hack. Could do repo first, plugin wrapper later.)
4. **Escalation default** — should the template ship the full byte-exact HMAC channel, or the post-DEC-046 model (confirmation card for routine `.claude/` writes, HMAC/never-escalatable wall only for the small hard core)? The run history says the lighter model is the right default; the heavy channel could be an opt-in hardening flag for higher-stakes domains.
5. **Solo vs team** — the current design assumes one human owner (one approval terminal, one register). Is multi-owner in scope for the template, or explicitly not?
6. **Windows-first?** — you run on Windows; the corpus's Windows fixes (interpreter probe, encoding declarations) are landed or proposed piecemeal. Should the template's host check treat Windows/Git-Bash as a first-class supported host (recommended, since it's your deployment reality) with the encoding/CRLF rules made mandatory?

---

## Appendix A — Load-bearing artifact contracts (freeze these during extraction)

Hooks and scripts parse every one of these by shape. Any drift breaks the harness silently.

1. **WIN row**: id `WIN-M{n}-{nn}`; script-decidable verify command exiting 0/non-0; wrapper `make win-m{n}-{nn}`; SPEC-ID column; evidence at `docs/evidence/M{n}/`; a row without a verify command is a setup defect, never adjudicated.
2. **Proof map**: contracts table with frozen column names `win` and `selector` (parsed by name); each selector must collect ≥1 test; output `docs/evidence/M<n>/proof-map.md`, regenerated at HEAD at ship.
3. **DECISIONS entry**: `## DEC-nnn — <title>`; `**Date.** / **Status.** ACTIVE|SUPERSEDED by DEC-mmm / **Decision.** ≤120 words / **Default/config.** / **Supersedes.** / **Affected.** / **Archive.**`; ids permanent, never reused; hot file ≤250 soft / 300 hard; every cited id must resolve; archive INDEX required; simulation line `Simulated against <n> frozen rows; <k> changed meaning: <list>` mandatory on frozen-surface adjudications.
4. **findings.md ledger**: columns `id | source | severity as filed | file:line | finding | disposition | rationale | DEC`; severity-as-filed never edited; row count equals findings filed across board raw outputs; rationale caps FIXED ≤40 words, ACCEPTED/DEFERRED/WAIVED ≤80 words + mandatory DEC id; no probe transcripts in cells (raw output → `docs/evidence/M<n>/probes/`).
5. **Board raw outputs**: `.pipeline/reviewer-findings.md`, `.pipeline/security-findings.md`; one numbered finding per item, `1.` at line start (the counter's parse shape).
6. **Manifest/amendments**: `.pipeline/plan-files.txt` one path per line; `.pipeline/manifest-amendments.txt` lines `<path><space>DEC-nnn [optional note]` — one shared parser between Stop gate and check_done; each amendment carries an impact line.
7. **Checkpoint artifacts**: `.pipeline/checkpoints/<n>-<stage>-jump.md` (7 sections, ≤500 words), `-evidence.txt` (script-only), `-clear.md` (self-written, ≤200 words, named spot-check, final line alone `CLEAR` / `BLOCK: …` / `ESCALATE: …`), `-fast.md`; FULL mandatory at 4 points; auto-promotion triggers; block cap 2.
8. **Verify artifact**: `.pipeline/verify-last.json` `{tier, head_sha, dirty_hash, exit, tail, timestamp}` — read, never re-derived.
9. **TDD artifacts**: `.pipeline/red-baseline.txt` (mechanical) vs `tdd-red-evidence.md` (self-report) — the reviewer's cross-check pair; green-on-arrival disclosure convention.
10. **Ship consent**: `.pipeline/ship-consent.json` `{pr, head_sha, base, question, options_offered, answer, answered_at}`; guard matches `pr` + `head_sha` before merge/push-main; a record, not a control — branch protection is the control.
11. **Run lifecycle markers**: `.pipeline/run-active` (milestone id inside; gates inert without it), `ready-to-ship` (tier switch), `run-idle`; `gc_prune.sh archive M<n>` at closure. (§4.1 item 4: give these a scripted writer/reopen/close in the template.)
12. **Dispatch env contract**: `PIPELINE_DISPATCH_ID` always; `PIPELINE_TEST_SCOPE` + `PIPELINE_PARTITION_GLOB` for writers — two distinct globs per partition (developer: src+config never tests; test-writer: tests only); review SHA for reviewers. NOTE HA-045: env vars do not reach hook environments from the Agent tool — the template must carry these via disk (R-009-11 shape).
13. **Events/metrics**: `.pipeline/run-events.jsonl`, `run-metrics.json`, `cmd-log`; `pipeline-event.sh decision_card "reason=… answer=…"` after every card; `run_metrics.py --markdown` emits retro §2 verbatim; null-not-zero convention.
14. **Retro corpus**: `runs/NNN-<milestone>-<outcome>.md`, closed outcome-token set `shipped|nogo|halted|abandoned|superseded|awaiting-ship`, ≤220 lines; predecessor re-measurement; 5-run consolidation; ACTIVE-LESSONS <100 lines; recurrence ≥3 → MUST-FIX; every MUST-FIX names a test that fails on recurrence *and* is payload-driven (anti-L-16); `PENDING-HUMAN-ACTIONS.md` ranked with recurrence column, n≥3 printed at session start.
15. **Escalation**: rule-id partition (NEVER / ALLOWED / control files); refusal marker "This refusal is ESCALATABLE" + id; byte-exact sha256 (resulting-file hash for writes → prefer Write over ambiguous Edit); single-use, ~30-min TTL, run-bound; key `secrets/escalation.key` 0600 gitignored agent-denied; `approve.sh --disclose <check-id>` binds to failure text, renders DISCLOSED never PASS, reprinted at every block; ledger agent-unwritable.
16. **Decision Card**: AskUserQuestion only; Situation/Why/Blast-radius preamble; 2–4 options, first `(Recommended)` with confidence; `Escalate to <arbiter>` on material/Hard-Stop/low-confidence cards; mandatory `Prior rulings:` grep-paste on constant/rule/control changes; one card at a time; journaled + event-logged; silence = no.
17. **Misc conventions**: test names carry requirement ids; contract-declared `-k` substrings are WIN-load-bearing; Conventional Commits, one green cycle per commit; docs committed separately from implementation; `contracts.md` index + per-partition slices; research.md 5 fixed sections, never-renumbered ledger, committed before verification; `research-verification.md` overlay; `gap-analysis.md` 3-column (currently defined only in the stale PIPELINE.md — must move); `context-live.md` one screen; caps: build-verify 3/partition, review-fix 2, clear-reviewer blocks 2, stop-gate 3, repeat-failure hash-stop, `MAX_RUN_SECONDS`.
18. **Recap (humanizer) contract**: `.pipeline/recap.md`; exactly five section headings (`What got done` / `Where the project stands` / `What's next` / `Issues you should know about` / `How close to launch`); ≤400 words; written after the retro and before the Ship Prompt; issues cited by §5.5 name; every claim traceable to an on-disk artifact — no new numbers, no new claims; never cited as evidence by any gate or card.
19. **Naming doctrine** (§5.5): filed items carry agent-authored kebab-case names, ≤5 words; multi-step efforts number as `<name>-1..n`; names permanent, never reused, never renamed (supersede instead); uniqueness checked at filing; generic names rejected by the narrative check; parsers for contracts 3/4/6/14 updated in the same changeset as their writers.

---

*Prepared by the Cowork audit session of 2026-08-20. No repository files were modified. Analysis fan-out: control layer, doctrine/roster, and iteration history were each independently audited and then synthesized; findings above cite file:line or run/lesson ids so they can be re-verified.*
