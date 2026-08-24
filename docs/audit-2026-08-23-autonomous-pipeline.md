# Ratchet v1.2.1 — Autonomous-Pipeline Audit

**Date:** 2026-08-23 · **Scope:** the full harness as staged (docs, doctrine, 12 agent seats, 23
hook scripts, installers, learning loop) audited as a fully autonomous agentic pipeline: a third
party fills SPEC/MILESTONES from an idea, the pipeline does the development, and the pipeline is
expected to learn on its own. Findings marked **[verified]** were reproduced by running the actual
hooks against crafted payloads in a sandbox.

---

## Executive summary

Ratchet is an unusually disciplined harness. The ownership partition, fail-closed gating,
mechanically-enforced red phase, content-hash-bound approvals, and event-log-grounded retros are
ahead of most of what industry leaders publish. Its learning loop already matches the shape of the
2025–2026 state of the art (ACE-style curated playbooks, recurrence-based promotion, human-gated
self-modification).

Four things keep it from earning its own claims today:

1. **The enforcement layer has verified bypasses.** The worst is that dispatch/attribution state
   lives in agent-writable `.pipeline/`, so a constrained agent can widen its own write scope.
   Several indirection classes (heredoc-fed interpreters, awk, variable/symlink indirection, xargs
   placeholders) get past `guard.sh`'s effect analysis, mitigated today only by the narrow
   permission allow-list.
2. **The metrics spine is partially disconnected.** `run_metrics.py` counts event types
   (`gate_block`, `refusal`, `dispatch`, `verify`, `commit`) that no hook emits — hooks emit
   `red_gate_block`, `guard_block`, `scope_block`, `dispatch_baseline`, `verify_ran` instead — so
   most counters render "not instrumented." **[verified]** There is no speed metric beyond
   whole-run work/wall seconds: no per-stage durations, no token/cost accounting, no
   human-wait time, no throughput.
3. **The orchestrator's always-loaded context (~19k tokens of doctrine before contracts) is
   several times above every published industry norm**, and the doctrine's redundancy-by-design
   compounds it.
4. **The loop learns but does not yet close autonomously.** Nothing verifies that a proposed
   refinement was ever applied; no run driver chains milestones; approvals die with a 30-minute
   TTY-bound TTL — so "fully autonomous" today means "autonomous between human checkpoints."

None of these is fatal, and all four have concrete fixes below. The pipeline's honest self-audits
(`docs/audit-2026-08-22.md`, `docs/edge-case-audit-2026-08-22.md`) already know about several —
which is itself evidence the loop works.

---

## 0. Audit against the four goals

**Speed.** Hook overhead is real but small (~62 ms per Bash call on Linux; plausibly 0.5–2 s per
call under Git-Bash where `fork()` is expensive). The dominant costs are structural: a
1-partition run's serial spine is ~14 opus-class dispatches plus four FULL checkpoint chains
(evidence → scribe → clear-reviewer, strictly serial), plus an end-of-run tail
(security checkpoint → Stage-6 checkpoint → retro → humanizer → ship) that is fully serial. Human
wait (Ship Prompt, TTY approvals) dominates elapsed time and is deliberately excluded from the work
budget — and is unmeasured. See §4.

**Accuracy.** The strongest part of the design. Red phase mechanically confirmed; verify results
cached in `verify-last.json` as the single source of truth; proof map ties every WIN row to a
named test; the reviewer runs mission-trace and claim-verification lenses; contradiction detection
in `run_metrics.py` cross-checks counters against each other. Main accuracy risk is drift the
suite can't see: `retro.md:40` promises "time per stage" in run-metrics.json — nothing computes
it **[verified]** — and the counter/event mismatch above is the harness's own named
"reader-writer-drift" failure class, live in its metrics spine.

**Code security.** Two independent layers (settings `deny[]` + hooks) protect the crown jewels,
and the approval spine is cryptographically sound (HMAC key never in argv/env, byte-exact
single-use approvals, atomic consumption, fail-closed on every dependency absence found). The
verified holes are catalogued in §0.1. The permission allow-list is currently the real wall for
several of them; any future widening of `allow[]` turns them into live holes.

**Potential to better itself.** The corpus, templates, recurrence mechanism, and supervisor
changesets are excellent. What's missing is closure verification (was the refinement applied? did
the metric move?), an outcome signal per lesson, and automation of the export/consolidation
plumbing — which is exactly what the `agent-development-export` tool in §5 is for.

### 0.1 Security findings (enforcement layer)

| # | Sev | Finding | Status |
|---|---|---|---|
| F1 | HIGH | Dispatch globs + attribution baselines live in agent-writable `.pipeline/dispatch/` (only `.pipeline/escalations/**` is denied — `settings.template.json:208`). Agent can rewrite its own partition glob (reproduced: blocked write → edit glob to `**` → identical write allowed) and forge exact-mode attribution. | **[verified]** |
| F2 | HIGH | `python3 <<'EOF' … EOF` (heredoc/stdin-fed interpreter) bypasses the inline-interpreter rule (`guard.sh:544-565` requires a `-c`/`-e` token); reproduced writing `.context/SPEC.md`. Mitigated: not in `allow[]`, so unattended runs stall on a prompt instead of executing silently. | **[verified]** |
| F3 | HIGH | `awk`/`gawk` (and ed/ex/tclsh/Rscript/lua) are not in the interpreter list and not modeled as writers; `awk 'BEGIN{print "x" > ".context/SPEC.md"}'` and a `getline`-based read of `secrets/escalation.key` both pass. Same allow-list mitigation. | **[verified]** |
| F4 | HIGH | Variable indirection (`T=.context/SPEC.md; printf x > "$T"`) and symlink indirection (`ln -s` from a protected source, then write through the link) defeat path detection. The settings `deny[]` layer also cannot see through these for Bash. | **[verified]** |
| F5 | HIGH | `echo <target> \| xargs -I{} cp evil {}` hides the write target as the literal `{}`; reproduced overwriting a control-set file. (The repo's own edge-case audit had already found the `xargs rm` variant.) | **[verified]** |
| F6 | MED | `ship-consent.json` is agent-forgeable and the guard's consent check passes on a forged record; matches documented design (record, not control) but depends entirely on the `ask` prompt + branch protection — and `branch-protection-missing` is still an OPEN pending action in the staged tree. | **[verified]** |
| F7 | MED | With neither jq nor python3, `rt_json_field`'s sed fallback fails **open** for command extraction (`hooklib.sh:185-230`), unlike the consent path which correctly blocks. | analysis |
| F8 | MED | The work-budget halt is escapable via agent-invocable `gc-prune.sh archive` + `start`, which mints a fresh `RUN_START`. | analysis |
| F9 | MED | `escalation-lib.sh` (1,771 lines) is sourced on every guard/scope-guard invocation but only needed on refusals; the command is tokenized ~4×. Lazy-sourcing is the single biggest hook-latency win. | **[verified]** |
| F10 | LOW | `find … -exec <anything>` is misclassified as `delete-scope` (conservative, but wrong rule and wrong args checked). | **[verified]** |
| F11 | LOW | `test_hooks.py` covers direct write-effect forms well but has zero coverage of the indirection classes F1–F5 — precisely the riskiest logic. | analysis |

Recommended order: wall or sign `.pipeline/dispatch/**` (F1) first — it is the only finding not
backstopped by the permission layer; then extend the interpreter/heredoc/placeholder detection
(F2/F3/F5) and add negative tests for every class (F11); document F4 as a known limit with the
settings layer as the real wall; make command extraction fail closed (F7); carry cumulative work
across archive/start (F8); lazy-source the escalation lib (F9).

What the design gets right, so this reads as an audit and not a teardown: effect-based write
detection genuinely works for direct forms including writer-verbs mid-command; approvals are
content-hash-bound with tamper re-derivation and never echo attacker bytes; fail-closed is applied
consistently on ignorance (missing jq → block, unknown rule id → never-escalatable); the HMAC key
handling avoids argv/env leaks and verifies gitignore effectiveness with a probe file; format.sh's
exclusion of `.claude/` protects approval hashes from being invalidated by a formatter.

---

## 1. Current methods for making the pipeline learn (and what to adopt)

The 2025–2026 consensus: for a Claude Code harness (no weight access), improvement comes from
**context engineering, not training** — and the published results say it works. GEPA (reflective
prompt evolution over full execution traces, ICLR 2026) beat GRPO-style RL by 6–20% with up to
35× fewer rollouts. The RL literature (RLVR, SWE-RL, TTRL) is relevant mainly as a design
principle Ratchet already embodies: **make the reward verifiable** — script-decidable WIN rows are
the context-engineering version of a verifiable reward. Keep hardening the mechanical record
rather than letting any agent grade itself; LLM judges have measurable self-preference bias and
are foolable by superficial tokens.

What the research says about Ratchet's specific loop:

**ACE (Agentic Context Engineering, arXiv:2510.04618) is the direct analogue and carries the
direct warning.** Its central finding is that iterative whole-file LLM rewrites of a lesson file
cause *context collapse* — each rewrite erodes detail ("brevity bias"). Ratchet's every-5th-run
full rewrite of `ACTIVE-LESSONS.md` under a 100-line cap is precisely that failure mode. The fix
ACE validates (+10.6% on agent benchmarks): **structured incremental delta updates** — itemized
lessons with stable IDs and helpful/harmful counters, edited item-by-item, never regenerated
wholesale. Ratchet's named-lesson identity and recurrence counters are already 80% of this;
change the consolidation contract from "rewrite the file" to "apply per-item deltas."

**Dynamic Cheatsheet / Voyager: the highest-value memory entries are executable, not prose.**
Cached procedures produced the dramatic gains (10%→99% on Game of 24). Ratchet's analogue: a
lesson that stabilizes should graduate out of the always-loaded prose file into (a) a hook or
check — deterministic enforcement, which Anthropic's own guidance says is where enforceable rules
belong — or (b) a Claude Code *skill* (progressive disclosure: only name+description always
loaded). `ACTIVE-LESSONS.md` should tend toward empty, not toward full: a full lessons file is a
backlog of unautomated enforcement.

**GEPA/trace-level reflection:** the retro already reads the mechanical record first — good.
The upgrade is to keep *scored variants*: when a refinement changes an agent definition, record
which variant ran in each run's metrics sidecar so consolidation can compare outcomes instead of
trusting the retro's rationale. (A Pareto-set of prompt variants, not a single monotonically
edited doctrine.)

**Meta-agent search (ADAS/AFlow):** research-only. No production vendor reports unsupervised
search over its own harness; human-gated supervisor changesets are the universal industry norm.
Ratchet is already correct here — do not automate `.claude/**` edits.

Concrete adoptions, in order of value: (1) per-item delta consolidation with helpful/harmful
counters; (2) a graduation path lessons → hooks/skills; (3) closure verification — a check that a
refinement marked applied actually landed (grep its invariant) and that its named metric moved;
(4) variant tagging in metrics sidecars; (5) optionally, a GEPA-style offline pass over archived
run events to propose agent-definition edits as supervisor changesets.

---

## 2. Context and rules volume vs. industry norms

Measured always-loaded orchestrator context (tokens ≈ words × 1.33):

| Source | Lines | ~Tokens |
|---|---|---|
| `doctrine/CLAUDE.md` (imported every session) | 929 | ~11,200 |
| `doctrine/PIPELINE.md` (imported) | 421 | ~4,400 |
| `.context/` three files (placeholders today; grow with the project) | 88 | ~930 |
| Session-start injection (run banner, context-live ≤150, ACTIVE-LESSONS ≤100, pending actions, selftest) | ≤~550 | ~2–3,000 |
| **Orchestrator baseline** | | **~19,000** |

Each delegated seat carries its definition (~1,150–5,100 tokens; `retro.md` is the outlier at
~5,100) plus the 5-item delegation packet — the packet design itself is excellent and matches
Anthropic's "lightweight identifiers / just-in-time retrieval" guidance exactly.

The norms: Anthropic publishes no line count but the per-line test ("would removing this cause
mistakes?") and the explicit failure mode — "bloated CLAUDE.md files cause Claude to ignore your
actual instructions." Cursor: keep rules under 500 lines, split into scoped rules. Factory (the
only hard cap published): 80k characters (~20k tokens) *maximum* initial load, "keep the top
dense." Devin: no monolith at all — many small trigger-scoped knowledge items. Anthropic's
subagent guidance: return 1–2k-token distilled summaries.

Verdict: Ratchet sits at Factory's *ceiling* and several times above the Anthropic/Cursor
recommended shape. The redundancy is deliberate ("the law is stated where a reader will meet it")
and self-tested for consistency, which removes the usual drift objection — but not the attention
cost: an instruction's probability of being followed degrades with everything loaded beside it.
The individual caps (ACTIVE-LESSONS 100 lines, context-live 150, checkpoint summary 500 words,
DECISIONS rollover) are all well inside norms and better-enforced than anything the leaders
publish.

Recommendations: (a) split CLAUDE.md into an always-loaded core — laws, ownership partition,
stop points, delegation packet, ~250–300 lines — and stage-triggered sections loaded as skills or
read on demand the way TEMPLATE.md already is (the R9 fix that dropped TEMPLATE.md from the
import is the pattern; apply it to the rest); (b) apply the per-line deletion test to
PIPELINE.md's overlap with CLAUDE.md — keep the stricter statement in exactly one place and
reference it; (c) hold agent definitions under ~1,500 tokens, moving their law-block duplication
to a shorter canonical citation (the suite already compares copies; it can compare references).

---

## 3. Language and stack support (Node.js/Python and beyond)

Yes — for the *managed project*, Ratchet is configurable for both Node.js and Python today, and by
design for anything else. The harness never contains a test command; it binds a 13-variable
command interface per stack pack (`VERIFY_CMD`, `FAST_TEST_CMD`, `SCOPED_TEST_CMD`,
`RED_TEST_CMD`, `COLLECT_TESTS_CMD`, `SECRETS_SCAN_CMD`, `DEP_AUDIT_CMD`, `FORMAT_CMD`,
`FORMAT_EXTENSIONS`, `TEST_PATH_REGEX`, `TEST_SURFACE_REGEX`, `FAILURE_LINE_REGEX`, `STACK_NAME`).

v1 ships three packs: `python-pytest` (reference; uv-aware, ruff format, gitleaks, pip-audit),
`node-jest` (npx jest, prettier, npm audit, gitleaks), and `generic` (every command empty; gates
that need one SKIP with a loud notice — valid for any language at reduced assurance). Auto-detect:
pyproject/setup.py/pytest.ini → python; package.json → node; else generic.

Adding Go, Rust, etc. is one new file in `.claude/hooks/stack/` binding the 13 variables — no code
changes elsewhere. Two real caveats: (1) `install.sh:848` rejects unknown `--stack` names, so a
new pack is added post-install and selected via `RATCHET_STACK` or the `stack/active` marker;
(2) the installer's permission-allowlist tables hardcode python/node tool entries, so a new
stack's commands hit permission prompts unless the pack defines `STACK_ALLOW_ENTRIES`. Worth
fixing both if new languages are planned.

Separate fact: the harness's own runtime always needs bash 4+, git, jq (hard requirement), and
Python 3.8+ regardless of project language — and GitHub/`gh` only for the ship flow in v1.

---

## 4. Development speed: levers and metrics

**Is speed tracked?** Barely. What exists: whole-run `work_seconds` (idle >900 s folded out) and
`wall_seconds`; per-event ISO timestamps in `run-events.jsonl` (from which stage timings *could*
be derived — nothing derives them); a 3-column cross-run trend (escalations, red-gate blocks,
work-seconds). What does not exist: per-stage/per-dispatch durations, token or cost accounting,
human-wait time (invisible by design since idle folds out), retry latencies, throughput (WIN rows
per hour), or any time-to-merge measure. And the counter/event name drift (§0) means even the
block/refusal counters currently render "not instrumented" in real runs. **[verified]**

Fix first, then optimize — you cannot speed up what you don't measure:

1. **Reconnect the metrics spine.** Either emit the canonical types (`gate_block` with
   `gate=red|stop|subagent`, `refusal`, `dispatch`, `verify`, `commit`) from the hooks, or teach
   `COUNTER_SPECS` the real names. One scoped commit each, suite between.
2. **Derive stage durations** from existing event timestamps (`run_start` → `dispatch_baseline` →
   `checkpoint_evidence` → …). Zero new instrumentation needed; it's a pure reader.
3. **Add token/cost telemetry.** Claude Code exports OpenTelemetry metrics natively
   (`token.usage`, `cost.usage`, `lines_of_code.count`, `code_edit_tool.decision` — the
   edit-acceptance rate is a direct human-intervention proxy). Even without an OTel collector,
   tokens-per-merged-PR and cost-per-run are the industry-standard efficiency metrics.
4. **Measure human-wait explicitly** (time between a Notification event and the next tool event)
   instead of only folding it out — it is the largest real-elapsed-time cost and currently the
   only invisible one.

**Speed levers, ranked by expected effect:**

- **Kill human-wait: the async approval channel + run driver** (already item 8 in the repo's own
  audit). A 30-minute TTY-bound approval TTL that dies at gate closure guarantees overnight
  stalls; milestones never chain, so every run ends parked. This dwarfs every compute
  optimization.
- **Pipeline Stage 3:** nothing today runs `test-writer(P2)` while `developer(P1)` builds; the
  doctrine permits it, no mechanism orchestrates it. For multi-partition runs this is the largest
  in-run win.
- **Overlap the end-of-run tail:** retro + humanizer can run while the push/PR-open proceeds;
  today they serialize in front of it.
- **Fold the double checkpoint at the end** (post-security FULL + Stage-6 FULL back-to-back) when
  the diff between them is empty.
- **Hook latency:** lazy-source `escalation-lib.sh` (F9), tokenize once — matters most on
  Git-Bash where per-call cost is plausibly 0.5–2 s.
- **Model-tier discipline is already good** (haiku reads, sonnet builds, opus judges); the next
  saving is caching scout/researcher outputs across runs on an unchanged repo region.

Benchmark the harness, not just the model: Terminal-Bench evaluates the harness+model pair;
SWE-bench Verified/Pro for the model-level baseline. A 20-task internal eval set (Anthropic's own
recommended starting point) against the metrics above would make every future harness change
A/B-able — which is exactly what the export tool in §5 feeds.

---

## 5. `agent-development-export.sh/ps1` — the plan

Full specification in `docs/plan-agent-development-export.md`. Summary: a read-only,
stdlib-only exporter that gathers everything the learning loop needs from the current project —
metrics sidecars, run-events (with derived stage durations and human-wait), escalation ledger,
lessons/refinement state, closure verification (did applied refinements actually land? asserts
still failing on mismatch?), doctrine/context-size measurements, and environment fingerprint —
into one versioned `export-bundle.json` + human-readable summary, redacted by default, suitable
for feeding the next Ratchet iteration, a cross-project fleet view, or an offline GEPA-style
optimization pass. It is proposed as a manual, agent-invocable script (same class as
`run_metrics.py`), emitting its own `export_run` event, failing loud-and-partial (a missing
source becomes a named gap in the bundle, never a silent omission), with byte-identical
re-runs on unchanged state so exports are diffable.

---

## 6. Ratchet as a harness and pipeline: how it gets better

**As a harness (containment + correctness):** close F1 first (sign or deny
`.pipeline/dispatch/**`) — it is the one hole the permission layer does not backstop. Extend
guard.sh's interpreter detection to heredoc/stdin forms and code-runners, refuse unprovable write
targets (xargs placeholders) the way push-targets are already refused, and add a negative test
per bypass class so the suite pins the fix. Make the sed JSON fallback fail closed. Then be
honest in the README that the Bash guard is a best-effort static layer and the settings `deny[]`
plus branch protection are the walls — the design already half-says this; saying it fully makes
the security model auditable. Finally: the staged tree's three OPEN install actions
(branch-protection-missing, spec-and-milestones-unfilled, webhook-never-configured) mean the
*actual* merge control is not yet engaged — that is a deployment fact, not a design flaw, but
autonomy without branch protection is autonomy on the honor system.

**As a pipeline (throughput + autonomy):** the three structural builds, in order — (1) the async
approval channel (signed approvals mintable from a phone/webhook response, TTL survives gate
closure); (2) the run driver that chains M*n* → M*n+1* and pages instead of parking; (3) Stage-3
pipelining. Then widen the funnel at the front: the TEMPLATE.md interview is the right mechanism
for third-party idea intake — add a non-interactive mode (answers from a file) so an external
agent can draft SPEC/MILESTONES programmatically and hand the human a diff to approve, which is
your stated use case.

**As a learning system:** per-item delta consolidation (ACE), lesson graduation to hooks/skills,
closure verification, variant-tagged metrics — §1. The meta-metric worth adding to every
consolidation: *lessons retired per window* (graduated to enforcement or resolved with evidence),
which measures whether the loop is actually converting experience into mechanism, not just
accumulating prose.

**Known gaps the repo already tracks** (kept visible here so they aren't lost): `install.ps1`
never executed on real Windows; live `gh pr merge` success path unexercised; `COMMIT_SCOPE_LINES`
defined but read by no hook; `local-patch.sh` referenced but unimplemented; no real milestone ever
run end-to-end — the harness is proven against its own suite, not yet against a project. Running
one real milestone (even a toy) is the single highest-information next step for the entire list
above.

---

## Sources

Anthropic — Effective context engineering for AI agents: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents · Claude Code best practices: https://code.claude.com/docs/en/best-practices · Agent Skills: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills · Multi-agent research system: https://www.anthropic.com/engineering/multi-agent-research-system · Claude Code monitoring (OpenTelemetry): https://code.claude.com/docs/en/monitoring-usage · Emergent misalignment from reward hacking: https://www.anthropic.com/research/emergent-misalignment-reward-hacking

Research — ACE: https://arxiv.org/abs/2510.04618 · Dynamic Cheatsheet: https://arxiv.org/abs/2504.07952 · Reflexion: https://arxiv.org/abs/2303.11366 · A-MEM: https://arxiv.org/abs/2502.12110 · Mem0: https://arxiv.org/abs/2504.19413 · GEPA: https://arxiv.org/abs/2507.19457 · TextGrad: https://arxiv.org/abs/2406.07496 · Voyager: https://arxiv.org/abs/2305.16291 · ADAS: https://arxiv.org/abs/2408.08435 · AFlow: https://arxiv.org/abs/2410.10762 · SWE-RL: https://arxiv.org/abs/2502.18449 · TTRL: https://arxiv.org/pdf/2504.16084 · RLVR analysis: https://arxiv.org/abs/2506.14245 · Self-preference bias: https://arxiv.org/html/2410.21819v1 · One token to fool LLM-judge: https://arxiv.org/html/2507.08794v1 · SWE-agent ACI: https://arxiv.org/abs/2405.15793

Industry norms — Cursor rules: https://cursor.com/docs/context/rules · AGENTS.md: https://agents.md/ · Factory AGENTS.md limits: https://docs.factory.ai/cli/configuration/agents-md · Devin Knowledge: https://docs.devin.ai/product-guides/knowledge · 12-factor agents: https://github.com/humanlayer/12-factor-agents · Cognition, Don't Build Multi-Agents: https://cognition.com/blog/dont-build-multi-agents · Letta memory blocks / sleep-time compute: https://www.letta.com/blog/memory-blocks/ · https://www.letta.com/blog/sleep-time-compute/

Benchmarks & measurement — SWE-bench Verified: https://www.swebench.com/verified.html · SWE-bench Pro: https://labs.scale.com/papers/swe_bench_pro · Terminal-Bench: https://www.tbench.ai/ · METR developer-productivity RCT: https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/
