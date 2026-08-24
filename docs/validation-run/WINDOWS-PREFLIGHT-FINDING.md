# Windows pre-flight finding — first real suite run on native Windows

**Date:** 2026-08-24 · **Context:** validation-run pre-flight, install into
`C:/Users/imsam/Desktop/ratchet-test` on native Windows (Git-Bash install path, `py -3` python).
**Outcome:** installer correctly refused to sanction a milestone — quick tier
**52 run, 43 passed, 9 failed, 2 errors, 1 skipped in 371.73s**.

This is audit finding U5 ("the suite has never completed on a real Windows host") producing its
first data. BUILD-NOTES' caveat — "run the suite on Windows before assuming" — was earned.

## The failures, grouped by root cause

### Root cause 1 — guard path normalization (9 of 11)

All seven `TestScopeGuardTier2b` failures and both `TestDenyPartitionIsConsistent` failures share
one root: path comparison against the repo root fails on Windows separators/casing
(`C:\Users` vs `C:/users`), so:

- in-manifest writes are misclassified as `manifest-scope-violation` (blocked when they should pass);
- the bootstrap exemption matches files it must not (a doctrine file was exempted; only the
  `.context/` contracts qualify);
- a control-set write falls through to a generic **escalatable** rule instead of never-escalatable
  `control-set-write` — the refusal offered an escalation id, which the deny partition forbids.

That last point makes this a **correctness** defect, not just a convenience one: on Windows the
never-escalatable wall is offering escalation ids. Likely home: `rt_repo_rel` / path
canonicalization in `hooklib.sh`, consumed by `scope-guard.sh` and `guard.sh`. Fix shape: one
canonicalization choke-point (lower-case drive letter, forward slashes, resolved casing) applied to
BOTH sides of every prefix comparison, plus quick-tier tests that feed the guards
`C:\`-style payloads on all platforms via monkeypatched roots.

### Root cause 2 — suite portability, not product (2 errors)

- `TestBashIsResolvedByProbe` → `WinError 2`: the relay-bash fixture is a shell script Windows
  `CreateProcess` cannot execute. Needs a `.bat`/`.exe` shim on Windows or a skip with a loud reason.
- `TestShipFlowIsTwoFactor` → `WinError 5`: the jq-absent simulation walks a
  `systemprofile\...\WindowsApps` PATH entry it cannot read. Needs the probe to tolerate
  unreadable PATH entries (which real `command -v` does).

### Root cause 3 — performance (no test failed; the number did)

Quick tier: **371.7s on Windows vs ~25s on Linux (~15x)**. Every hook firing spawns bash+python;
on native Windows that tax lands on every tool call of every run. Even fully green, native Windows
is not a viable host for this harness without a hook-latency strategy. WSL is the Windows answer,
possibly permanently — the README's Windows guidance should say so in these terms.

## What went right

The install-time verify refused to bless a red control layer and said why, with the correct next
command and an accurate LIKELY CAUSE. First wall to fire outside the dev tree fired correctly.

## Decisions

1. **Validation run proceeds on WSL** (observer plan step 2), repo inside the WSL filesystem
   (`~/ratchet-test`, not `/mnt/c/...`). Windows findings must not contaminate M0's harness findings.
2. **Windows port is its own later workstream**, scoped by this file: one normalization
   choke-point + two suite-portability fixes + a documented WSL-first stance and re-measured
   hook latency. Do not patch the control layer piecemeal before M0.
