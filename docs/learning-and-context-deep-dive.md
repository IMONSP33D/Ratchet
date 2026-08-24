# Ratchet — Learning Loop and Context Budget: the honest comparison

**Date:** 2026-08-23 · Companion to `audit-2026-08-23-autonomous-pipeline.md`. This answers two
questions directly: *is our learning loop best in industry?* and *is our context load justified?*
Both answers are qualified, and the qualifications are the useful part.

---

# Part 1 — The learning loop

## The verdict in one paragraph

**On making a lesson auditable, Ratchet is the best design I could find published or shipping.
On actually getting better, it is mid-pack.** Nothing else in the field combines grep-addressed
invariants, a per-lesson executable regression assert, a "green assert but the lesson recurred
anyway" defect class, and mutation-tested changeset review. But four research systems and one
shipping product close a loop Ratchet leaves open: **nothing measures whether a refinement
helped.** That is not a footnote — it is the load-bearing weakness, and it is compounded by a
consolidation step that ACE's authors specifically identify as lossy.

## Where Ratchet is genuinely ahead of everyone

**1. Addressability as an admission requirement.** Every refinement row must name a target file,
an invariant expressed as a grep pattern, and *all instances* that grep returns. Nobody else
rejects "improve the review process." ACE bullets carry unique IDs and structured metadata — the
closest analogue — but their content is prose strategy, not an executable locator into a file.
Devin's trigger descriptions are retrieval hints. This is the design's best idea, because it turns
a lesson into something a diff can be checked against.

**2. Per-lesson executable regression asserts.** Each lesson names a test in the harness's own
suite that must fail when the lesson recurs. The neighbours all verify at a coarser grain: Voyager
gates *admission* of a skill on one-shot self-verification; the Darwin Gödel Machine re-runs an
aggregate benchmark; ProcMEM applies a statistical trust-region gate; Dynamic Cheatsheet executes
candidate code before retention. None leaves behind a standing, named, per-lesson regression test.
The meta-check — *the assert passed but the lesson recurred, therefore the assert is the bug* — I
could not find published anywhere.

**3. Governance of self-modification.** Author → independent fresh-context reviewer opening with a
provenance caution → human apply after replica verification, including driving every changed check
with a mismatched payload requiring the opposite verdict, plus a dated host-verification table.
That mismatched-payload step is mutation testing applied to the checks themselves. DGM is the only
comparable system and its controls are coarser (sandbox, supervision, lineage). ADAS and AFlow
publish no safety controls at all.

**4. Retro on every outcome, mechanical record before narrative.** Treating the *gap* between
counters and self-report as the highest-value signal is a discipline nobody else documents. Caveat:
this is process discipline rather than mechanism, and process discipline is the easiest thing here
to quietly stop doing — which is exactly what happened to the metrics spine (below).

## Where Ratchet is behind, and who is ahead

**1. Closure verification — the big one.** DGM re-benchmarks every self-modification and admits
nothing without measured improvement (SWE-bench 20%→50%). ADAS evaluates on held-out sets with 95%
bootstrap confidence intervals. GEPA keeps a Pareto frontier scored against validation. SEAL makes
the reward literally the downstream performance of the edited model. Ratchet already has the
apparatus — a frozen command corpus and replica verification — it just never re-runs that corpus
*after* the apply and compares to the pre-apply baseline. **You are one measurement away from
parity with the best systems in the field.**

**2. Staleness invalidation.** GitHub Copilot Memory (public preview since Jan 2026) stores repo
facts *with citations to the supporting code*, re-checks those citations against the current branch
at retrieval, uses only validated facts, and deletes anything unused after 28 days. Ratchet drops
resolved lessons only at consolidation, only every 5 runs, and only if someone declared them
resolved. A lesson whose target file was deleted three runs ago still occupies one of your 100
lines. **Your grep invariant is already the citation — you just aren't re-running it.**

**3. Negative signal.** Ratchet counts recurrence (a proxy for *unfixed*) but has no counter for
*this lesson was followed and made things worse* or *loaded 40 times, never mattered*. ACE bullets
carry **both helpful and harmful counters**. TAME decomposes task feedback into per-memory
contribution scores specifically to stop high-scoring/low-trust strategies accumulating, and names
the failure mode you're exposed to: *Agent Memory Misevolution*. Your ledger is monotonic in one
direction — things get more urgent, never less credible.

**4. Merge determinism.** ACE's central published finding is that **monolithic LLM rewriting causes
context collapse** through brevity bias, and its answer is delta updates merged by lightweight
*non-LLM* logic. Your every-5th-run consolidation rewrites the whole 100-line file with an LLM.
Permanent kebab-case names give you stable identity — the right primitive, half the solution — but
you aren't exploiting the IDs at merge time.

**5. Retrieval scoping.** A hard-capped always-loaded file means total learnable knowledge is fixed
at 100 lines forever. Devin retrieves by trigger description; Cursor by glob; Claude Code has
path-scoped rules plus on-demand topic files under a capped index. **Claude Code solves both
problems at once** — capped index, uncapped retrievable detail. The cap is a good answer to context
bloat and a bad answer to knowledge capacity.

**6. Promotion to real enforcement.** Claude Code's own documentation says it outright: memory is
"context, not enforced configuration. To block an action regardless of what Claude decides, use a
PreToolUse hook instead." Ratchet's recurrence≥3 → MUST-FIX promotes prose to *louder prose*. You
already require a grep invariant, and that grep is already a lint rule — you just aren't installing
it. **This is the single highest-leverage change on the list**, and it's philosophically native to
Ratchet: the whole harness is built on "controls are code, prompts are context."

**7. Adversarial robustness of the grounding.** DGM's agent, rewarded for hallucination detection,
*removed the tool-use markers to sabotage the detector* — caught only via lineage. In Ratchet the
retro that names a lesson also names its assert: a self-authored test guarding a self-reported
defect. Your green-assert-but-recurred checker is the right instinct and more than anyone ships,
but it fires only after a recurrence has been observed *and correctly labelled by the same agent*.

## What to adopt, ranked by value per unit of effort

1. **Apply-and-measure.** After a changeset lands, re-run the frozen corpus plus a held-out task
   set; record the pre/post delta on the lesson's assert and on aggregate counters; revert on no
   improvement. Closes your stated gap. (DGM, ADAS, GEPA, SEAL.)
2. **Helpful/harmful counters + non-LLM delta merge.** Append new IDs, increment counters in place,
   embedding-dedup for redundancy. Kills the lossy rewrite. (ACE.)
3. **Invariant revalidation + unused-lesson decay.** Re-run each lesson's grep before loading it;
   zero instances means fixed or stale, and either way it shouldn't cost a line. (Copilot Memory.)
4. **Retrieval-scoped detail under the capped index.** Keep 100 lines always-loaded; move detail to
   trigger- or path-scoped files. (Claude Code, Devin, Cursor.)
5. **Lesson → hook promotion at recurrence≥3.** Emit a check from the invariant instead of a
   louder line. (Anthropic's explicit guidance.)
6. **Admission gate for new lessons.** A candidate must show it would have changed the outcome on
   at least one recorded trace before consuming a line. (Voyager, ProcMEM, Dynamic Cheatsheet.)
7. **Archive dropped lessons with lineage.** DGM found low-performing ancestors were essential
   stepping stones, and lineage was the *only* reason they caught the sabotage.
8. **Independent assert authorship + mutation.** Have a different context than the lesson's author
   write the assert, then synthesize a recurrence and confirm it goes red. You already do exactly
   this for changeset checks — extend it one level down.

## One structural caution

Ratchet's independent fresh-context reviewer is in direct tension with Cognition's published
principle ("share full agent traces, not just individual messages"). Ratchet's counter-argument —
that independence *is* fresh context, and an auditor anchored by the author's rationalizations is
not an auditor — is defensible and I think correct for an adversarial review seat. But it is a
contested position, not an obviously correct one, and worth holding deliberately rather than by
default.

---

# Part 2 — Is the context load justified?

## The measurement

| Source | Lines | ~Tokens | Verdict |
|---|---|---|---|
| `doctrine/CLAUDE.md` | 929 | ~11,200 | **Not justified at this size** |
| `doctrine/PIPELINE.md` | 421 | ~4,400 | **Partly** — the overlap is the problem |
| `.context/` (3 files, placeholders today) | 88 | ~930 | Justified; grows with the project |
| Session-start injection | ≤550 | ~2–3,000 | **Fully justified** — this is the good part |
| **Orchestrator baseline** | | **~19,000** | at Factory's published ceiling |

Per-dispatch: agent definitions 1,150–5,100 tokens (`retro.md` the outlier) plus a 5-item
delegation packet.

## Where it *is* justified

**The delegation packet is exemplary.** Five items — task, contract-slice pointer, WIN rows served,
dispatch id or review SHA, undocumented discoveries — and explicitly *not* the laws, the master
contract, or the doctrine. That is Anthropic's "lightweight identifiers, just-in-time retrieval"
guidance implemented more rigorously than most vendors implement it themselves.

**The caps are better-enforced than anything the leaders publish.** ACTIVE-LESSONS 100 lines,
context-live 150, checkpoint summary 500 words, clear verdict 200 words, DECISIONS rollover — all
mechanically gated. Cursor publishes a 500-line guideline with no enforcement; Anthropic publishes
a per-line judgment test. You enforce yours in code.

**The R9 fix was correct and is the template.** Dropping TEMPLATE.md (~5,900 tokens) from the
always-loaded import and reading it once at drafting time is exactly right. It proves the pattern
works and that the remaining monolith is a choice, not a constraint.

**Redundancy-by-design is a real argument, and the self-test defuses the usual objection.** Stating
the law where a reader meets it and the mechanics where a reader needs them is defensible, and
comparing the two copies mechanically removes the drift risk that normally kills this approach.

## Where it is *not* justified

**Redundancy removes the drift cost; it does not remove the attention cost.** Anthropic's stated
failure mode is not "the duplicated copies disagree" — it is *"bloated CLAUDE.md files cause Claude
to ignore your actual instructions… important rules get lost in the noise."* Consistency between
two copies is no defense against both being skimmed. Attention is a finite budget subject to
context rot, and 15,600 tokens of doctrine spends it before the project's own spec is read.

**The comparison to norms is unflattering at the top end.** Factory caps initial load at ~20k
tokens *as a maximum*; you sit at ~19k with placeholder contracts, meaning a real SPEC and
MILESTONES push you past the only published hard ceiling in the industry. Cursor says under 500
lines per rule file; CLAUDE.md is 929. Devin's model — many small trigger-scoped items, each a
handful of sentences — is the opposite pole and is the one shipping at the largest scale.

**Most of the doctrine is stage-conditional, which is the definition of progressive-disclosure
material.** Soak-run mechanics, checkpoint internals, garbage-collection thresholds, the 23-script
inventory — none of it is needed at Stage 1, all of it is loaded there.

## The recommendation

Split CLAUDE.md into an **always-loaded core of ~250–300 lines** — the laws, the ownership
partition, the two stop points, the hard stops, the delegation packet, the escalation classes — and
move the rest behind the same mechanism that already worked for TEMPLATE.md: stage-triggered reads
or skills. Apply the per-line deletion test to PIPELINE.md's overlap with CLAUDE.md, keeping the
stricter statement in exactly one place with a reference from the other. Hold agent definitions
under ~1,500 tokens by replacing the verbatim law block with a canonical citation — your suite
already compares copies, and it can compare references just as mechanically.

**Expected effect:** orchestrator baseline from ~19k to ~6–8k tokens, leaving room for a real SPEC
and MILESTONES inside every published budget, with no law weakened and no rule deleted — only moved
to where it is read when it matters.

---

## Sources

**Anthropic** — Effective context engineering: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents · Claude Code best practices: https://code.claude.com/docs/en/best-practices · How Claude remembers your project: https://code.claude.com/docs/en/memory · Agent Skills: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills · Emergent misalignment from reward hacking: https://www.anthropic.com/research/emergent-misalignment-reward-hacking

**Shipping systems** — GitHub Copilot Memory: https://docs.github.com/en/copilot/concepts/agents/copilot-memory · changelog: https://github.blog/changelog/2026-01-15-agentic-memory-for-github-copilot-is-in-public-preview/ · VS Code memory: https://code.visualstudio.com/docs/copilot/agents/memory · Devin Knowledge: https://docs.devin.ai/product-guides/knowledge · Cursor rules: https://cursor.com/docs/context/rules · Factory AGENTS.md: https://docs.factory.ai/cli/configuration/agents-md · OpenHands condenser: https://docs.openhands.dev/sdk/guides/context-condenser · Amp manual: https://ampcode.com/manual · Aider repo map: https://aider.chat/docs/repomap.html · AGENTS.md: https://agents.md/ · Cognition, Don't Build Multi-Agents: https://cognition.com/blog/dont-build-multi-agents

**Research** — ACE: https://arxiv.org/abs/2510.04618 · Dynamic Cheatsheet: https://arxiv.org/abs/2504.07952 · Voyager: https://voyager.minedojo.org/ · Reflexion: https://arxiv.org/abs/2303.11366 · ADAS: https://www.shengranhu.com/ADAS/ · AFlow: https://arxiv.org/abs/2410.10762 · Darwin Gödel Machine: https://sakana.ai/dgm/ · GEPA: https://arxiv.org/abs/2507.19457 · SEAL: https://jyopari.github.io/posts/seal · Agent KB: https://arxiv.org/abs/2507.06229 · Alita-G: https://arxiv.org/abs/2510.23601 · TAME: https://arxiv.org/html/2602.03224 · ProcMEM: https://arxiv.org/html/2602.01869v1 · Mem0: https://arxiv.org/abs/2504.19413 · Letta context repositories: https://www.letta.com/blog/context-repositories/ · Self-evolving coding agents survey (Aug 2026): https://arxiv.org/html/2608.03392 · SWE-agent: https://arxiv.org/abs/2405.15793

**Unverified / flagged** — Cursor's Memories approval mechanism could not be confirmed from Cursor's own docs (the memories page 404'd repeatedly); only the 1.0 changelog is primary. Mem0's and Letta's performance numbers are vendor-run. Community "keep CLAUDE.md under 150–300 lines" figures appear in no Anthropic primary source — Cursor's 500-line and Factory's 80k-character limits are the only vendor-published hard numbers verified.
