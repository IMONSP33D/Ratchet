# Reversion point — escalation channel removal (2026-08-24)

## The one command

```bash
git checkout pre-escalation-removal          # tag on decisions-2026-08-23-phase1
```

Tag `pre-escalation-removal` = commit `ffaa18a`, the last commit with the escalation channel
intact and the full suite green (173 run / 155 passed / 0 failed). Everything below that line was
verified working at that tag; nothing about reverting is speculative.

To reverse just this change while keeping later work:

```bash
git revert --no-commit <escalation-removal-sha>..HEAD    # or
git diff pre-escalation-removal HEAD -- harness/ install.sh | git apply -R
```

## What was removed

| File | Lines |
|---|---|
| `harness/.claude/hooks/escalation-lib.sh` | 1,777 |
| `harness/.claude/hooks/approve.sh` | 676 |
| `harness/.claude/hooks/escalate.sh` | 374 |
| `harness/.claude/hooks/esc_payload.py` | 368 |
| **total** | **3,195** |

Plus: the `--escalation-mode` install flag, `ESCALATION_KEY`/`_TTL_SECONDS`/`_LEDGER`/`_MODE`,
`ESCALATIONS_DIR`, `DOMAIN_NEVER_ESCALATABLE` (interview 8 questions → 7), the signing-key
generation at install, the postcondition baseline, the disclosure mechanism in `check_done.py`,
and the `escalation-store-write` / `approve-script-invocation` rule ids.

## What replaced it

Every refusal is final. The block message now carries the way forward: `g_alternative` in
`guard.sh` and `s_alternative` in `scope-guard.sh` map every rule id to what to do instead, exposed
as `guard.sh --explain <rule-id>`. `TestEveryRefusalCarriesAWayForward` asserts that every rule a
guard can emit has an entry — a wall with no door beside it is how an unattended run dies.

One rule changed class rather than losing an unlock: **repo-local `git config user.name` /
`user.email` is now allowed.** A fresh clone with no identity cannot commit at all, so an agent that
cannot set it is an agent that cannot work — this was the single most likely way an unattended run
died on its first commit. Everything else about repo config stays refused.

## The reasoning, so a future reader can re-decide rather than re-derive

All 15 rules the channel could lift were audited. None needed a human:

| Class | Rules |
|---|---|
| The agent can do it correctly itself | `push-target-unprovable`, `compound-git-form`, `manifest-scope-violation` |
| A fixed policy should decide | `git-config-write`, `inline-interpreter`, `gh-verb-off-surface`, `delete-scope` |
| Should never have been liftable | `git-remote-write`, `claude-dir-write`, `partition-glob-violation`, `run-lifecycle-file-write` |
| Mechanical | `decisions-hot-rollover` |
| Not approvals at all — they are caps | `commit-scope-oversize`, `stop-retry-cap`, `subagent-retry-cap` |

A channel that pauses an autonomous run to ask permission for a decision no human was adding
judgment to is a stall with a ceremony attached. The two real human stop points — the Ship Prompt
and a material Decision Card — are untouched, because those are questions where a human genuinely
adds judgment.

## What would make this the wrong call

Revert, or build the replacement described below, if a real run shows any of:

1. **A legitimate task becomes impossible**, not merely inconvenient — the agent needs something the
   alternatives cannot express, and stops dead rather than routing around.
2. **Repeated dead-ends on one rule.** The refusal log (`.pipeline/run-events.jsonl`, and retro §8)
   shows the same rule id blocking runs over and over. That means the wall is in the wrong place —
   which is an argument for moving THAT wall, not for restoring the channel.
3. **A wall you actually want to open case-by-case**, with a human genuinely weighing each one. If
   that turns out to exist, the modern replacement is not this HMAC ledger: it is an `ask` rule
   routed to a `canUseTool` callback in an SDK wrapper, or `permissionDecision: "defer"`. Both are
   documented in RATCHET-DECISIONS-2026-08-23 §4.1 and neither needs a signing key.

## Verified at removal

- Full suite: **168 run, 155 passed, 0 failed, 13 skipped**
- `guard.sh --selftest`: 22/22 rule ids declared and emitted
- `scope-guard.sh --selftest`, `check_done.py --selftest`, `gc-prune.sh --selftest`: pass
- Clean install end to end: `install-verify.sh` all green, deployment + host checks
- Confirmed still walled after removal: control set, governing corpus, secrets, force push,
  base-branch push/commit, dispatch store — each still refused at both layers
