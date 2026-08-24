# Ratchet 1.2.3 — release notes

The Windows/WSL release, and the one where the escalation channel goes.

## Breaking

**Every refusal is final.** The escalation channel — HMAC-signed, single-use, human-minted approvals
that could lift one byte-exact refusal — is removed (−3,195 lines). All 15 rules it could lift were
audited and none needed a human: each was something the agent should do correctly itself, something
a fixed policy should decide, or something that should never have been liftable.

Refusals now carry the way forward instead. Every rule maps to a "Do this instead:" line, readable
without triggering the block:

```bash
.claude/hooks/guard.sh --explain push-target-unprovable
.claude/hooks/scope-guard.sh --explain manifest-scope-violation
```

Gone with it: `--escalation-mode`, `ESCALATION_KEY`/`_TTL_SECONDS`/`_LEDGER`/`_MODE`,
`ESCALATIONS_DIR`, `DOMAIN_NEVER_ESCALATABLE` (the init interview is 7 questions, not 8),
install-time signing-key generation, the postcondition baseline, and `check_done.py`'s DISCLOSED
status — a red is a red.

**Newly ALLOWED:** repo-local `git config user.name` / `user.email`. A fresh clone with no identity
cannot commit at all, so an agent that cannot set it cannot work. Everything else about repository
config stays refused.

Reversion: tag `pre-escalation-removal`, and `docs/REVERSION-escalation-removal.md` for the full
reasoning plus the three observable conditions that would make it the wrong call.

## Fixed — Windows and WSL

**Path dialects (HIGH).** One directory has six legal spellings — `C:\r`, `C:/r`, `/c/r`,
`/mnt/c/r`, `/r`, `//wsl.localhost/D/r` — and every gate decision is a prefix comparison between
two of them. Only two were handled, so on Git-Bash nine gates failed: in-manifest writes refused,
the bootstrap exemption matching the wrong files, control-set writes falling through to a liftable
rule. `rt_canon_abs` now reduces all six to the spelling that works in the current shell, reading
the WSL automount root from `/etc/wsl.conf` rather than assuming `/mnt`.

**Case-sensitivity was decided from the wrong thing (HIGH, security).** It read `$OSTYPE` — which
answers "is the SHELL Windows". Under WSL with the repo on `/mnt/c`, that says no, so the guards
compared case-sensitively against an NTFS filesystem. Every deny list runs through that path:
`Guard.sh` did not match the control-set entry `guard.sh`. On the most common Windows setup there
is, the wall was one shift key wide, and nothing reported it. Now decided by the volume.

**Test-harness portability.** The relay-bash test truncated `C:\Program Files\...` at the space and
tried to spawn `C:\Program`; the jq-absent test crashed on an unreadable `WindowsApps` PATH entry
and silently degraded to an empty PATH. Both fixed.

**CRLF.** `install.sh` now actually writes the `.gitattributes` LF pin QUICKSTART already promised.
Without it a collaborator cloning with `core.autocrlf=true` gets CRLF hooks and every gate dies on
its shebang — on a machine that was never the install machine.

## Changed — install verification

**6 minutes → 0.5 seconds.** Install verification ran `test_hooks.py --quick`: 56 tests, 265 bash
spawns, ~371s under Git-Bash. That suite is *Ratchet's own development test suite* — it proves the
harness logic is right, which is a question about Ratchet, settled in CI, not about whether your
install worked.

New `install-verify.sh` answers the only two questions an install has: **did the files land**
(inspection, no subprocesses) and **does this machine run them** (bash, python, jq, git, path
reduction, case detection, and each guard firing once allow and once block). Verified against 10
deliberately broken installs. `--verify smoke|quick|full` still runs the old suite for harness
debugging.

## Changed — the updater

`ratchet-update.sh` rewritten as a real three-way template merge (1,477 → ~380 lines), plus three
defects a post-landing audit found in that rewrite: a KEEP file silently clobbered one release
later, `--adopt-baseline` reinstalling the tree it existed to preserve, and `CLAUDE.ratchet.md`
pinned at its install version forever.

## Performance

Both PreToolUse guards load their libraries lazily where possible; the allow path — the
overwhelming majority of tool calls — got ~14% faster. Under Git-Bash, where process creation is
emulated, the same fraction is considerably more wall clock.

## Honest limitations

1. **No milestone has been run yet.** M0 on a scratch project is the next thing, and it is the only
   thing that tests the harness as a product rather than as a test suite. See
   `docs/validation-run/`.
2. **The Git-Bash fixes are verified as strings, not on Windows.** The dialect reductions execute on
   any host via `RT_PLATFORM`/`RT_MOUNTROOT` overrides, so CI covers the WSL and MSYS branches — but
   the full suite has still never completed on a real Windows host.
3. **Native Windows is slow**, ~10–15x Linux: every hook firing spawns bash and sources the
   libraries. WSL with the repo inside the distro is the fast path, and the installer now says so
   with the number attached.
4. **`gh` is unexercised.** The refusals around the merge path are tested; the success path is not.
5. **The pager does not fire on run death.** Budget halts, repeat-failure stops and cap exhaustion
   end the run without a Notification event. Open, tracked in the 2026-08-24 audit as R2.
