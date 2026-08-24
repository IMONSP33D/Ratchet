# Ratchet 1.2.2 — release readiness

**Suite:** 203 passed, 0 failed, 7 skipped (baseline 1.2.1 was 190 passed).
**Selftests:** all 20 green. **Parsers:** 3 bash + 3 PowerShell (real pwsh 7.4.6), all clean.
**Version:** 1.2.2 consistent across all four hardcoded sites, now bound by a test.

## Blockers found and fixed

| # | Severity | Finding |
|---|---|---|
| 1 | **BLOCKER** | `install.ps1` did not parse. `Get-ShellVar` interpolated a bash `"${NAME:-}"` inside a double-quoted PowerShell string, where `$Name:` reads as a namespaced variable. PowerShell parses a whole file before executing any of it, so **the Windows installer had never been able to run at all** — masked because nobody had a PowerShell to try it on. |
| 2 | **BLOCKER** | Install was **not idempotent**, despite the README claiming it was. A jq closure bug (`def f(old; new)` binds closures, not values) meant the dedup subtraction always evaluated `old` as `null`, so every re-install appended a duplicate set of hook registrations — 8 `guard.sh` entries after 4 installs, each firing on every tool call. Measured before/after against a pristine control. |
| 3 | **BLOCKER** | The 1.2.2 version bump existed nowhere; four sites hardcode it independently with nothing binding them. Bumping only `VERSION` was demonstrated to produce an install reporting three different versions to three readers — one of them the agent's own session context. |
| 4 | HIGH | `install.sh --verify none` ran the **slowest** verification, uncapped (fell through to `full`'s empty flag, then skipped the budget cap). |
| 5 | HIGH | `install.ps1` ran the full suite unconditionally and uncapped — the ~25-minute path `install.sh` explicitly refuses to inflict on Windows. Now has `-Verify quick\|smoke\|full\|none`, default `quick`. |
| 6 | HIGH | `PIPELINE.md` "23 scripts" was wrong (25) and hid two real files: `interview.sh` and `esc_payload.py`, the latter mentioned in **zero** markdown files bundle-wide. |
| 7 | HIGH | `UPGRADING.md` documented a `local-patch.sh` escape hatch that exists nowhere at either end — shipped doctrine describing a file the harness does not have. |
| 8 | MEDIUM | `BUILD-CONTRACT.md` §5.6 read as an exhaustive never-escalatable list while being four rule ids short; `DISPATCH_DIR` was absent from the frozen-name selftest despite a never-escalatable rule now depending on it. |
| 9 | MEDIUM | The bundle shipped `harness/.pipeline/` test residue — real run tokens and target hashes — with no `.gitignore` anywhere. Removed; `.gitignore` added so it cannot come back. |

## README claims corrected during fact-check

- **jq was overstated.** "No jq means no Bash tool calls at all" is false — `hooklib.sh` falls back to Python's `json`, then to sed for non-security fields. jq is hard-required for the *ship-consent* decision specifically, which fails closed without it.
- "Five gates are Python" — all 8 hooks are bash; five *checkers* they call are Python.
- Control-set list was missing `settings.local.json` and `settings.template.json`.
- `scope-guard.sh` covers `NotebookEdit` too.
- Layout block omitted `.context/archive/decisions/`.

## Not fixed — carried into 1.2.2 knowingly

- `install.ps1` has still never been **run** on Windows. It now parses against a real PowerShell 7.4, which is how blocker #1 surfaced, but parsing is not running and 5.1 is not 7.4. `install.sh` under Git-Bash remains the verified path.
- `install.ps1` still does not write `.ratchet-version`/`.ratchet-manifest` (bash does), so a PowerShell install starts un-baselined and its first upgrade reports spurious `.local-*` copies.
- Guard bypasses F2–F5 (heredoc-fed interpreters, `awk`, variable/symlink indirection, `xargs` placeholders) remain open, mitigated only by the narrow permission allow-list.
- The escalation happy path (mint an approval, guard honours it once) is **skipped** in the suite — a headline feature resting on no executed test.
- `test_hooks.py` does not cover the installer's settings merge at all, which is why blocker #2 survived.
- No real milestone has been run end to end.

## Commit template

`.claude/commit-template.txt`, wired repo-locally via `commit.template` by both installers, never overwriting an existing one.

```
Version X.X.X: <what changed, at most three sentences>
```

Scoped to release commits only. The agent's per-cycle Conventional Commits use `git commit -m`, which never opens an editor and so never reads the template — the two formats cannot collide.

## Verdict

Ship-ready **for the Linux/macOS/Git-Bash path**. The Windows PowerShell path is now syntactically valid for the first time but remains unexercised; treat its first real run as a test, not a deployment.
