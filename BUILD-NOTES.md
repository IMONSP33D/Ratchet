# Ratchet 1.2.1 — build notes

What this is, what was verified, and what was not. Read the honest-limitations section
before you trust anything here in anger.

## Provenance

Ratchet is a generic extraction of a private, battle-tested Claude Code delivery pipeline
that ran nine real milestones over roughly a month. The audit that motivated the extraction
is `docs/audit-and-blueprint.md`. Ratchet is a **fresh generic implementation** of that
pipeline's doctrine, not a find-and-replace of its files: the original's coupling was small
but its known defects were real, and a template mass-produces whatever it ships with.

## Verified in this build

- **Self-test: 180 tests, 173 pass, 0 fail, 7 skip, ~80s.** Run `python3 .claude/hooks/test_hooks.py`.
  (Test count grows with the suite; re-run to check the current numbers rather than trusting this line.)
- **`install.sh` end-to-end** into two scratch repos: clean install, idempotent re-install,
  settings.json merge with backup, gitignore verification via `git check-ignore`, key
  generation at 0600, and uninstall (which restores settings and deliberately preserves your
  content — domain pack, evidence, findings, secrets — and says so).
- **Live guard behaviour** on the installed repo: secrets read blocked, evidence deletion
  blocked, force push blocked, ordinary test command allowed.
- **Every shell file `bash -n` clean; every Python file compiles; settings template is valid JSON.**
- **Zero source-project nouns** anywhere in the harness (enforced by a test, not by hope).

## Defects found and fixed during integration

Found by the self-test, i.e. the suite earned its keep before shipping:

| defect | severity | fix |
|---|---|---|
| `git push --delete origin main` was permitted with consent | HIGH — deletes the base branch | `--delete`/`-d` now classed with force-push, never-escalatable |
| bare `git push` target was assumed from the current branch | HIGH — `push.default=matching` pushes the base branch from anywhere | new rule `push-target-unprovable`: fail closed, make the caller name the refspec |
| `*` crossed `/` in partition globs (`src/*.py` admitted `src/deep/a.py`) | MEDIUM — a partition is silently wider than the architect declared | segment-aware matcher; `**` crosses, `*` does not |
| a missing escalation key was never surfaced | MEDIUM — every "ESCALATABLE" refusal is a dead end and you find out mid-run | session-start now probes the approval channel and says so in plain words |
| scope-guard bound approvals to the path, not the resulting bytes | MEDIUM — no approval could ever match | passes the target sha through |
| **the new host check itself rejected working hosts**: `"$PY"` was quoted, so a multi-word interpreter (`py -3`) exec'd a file literally named "py -3", produced nothing, and read as "bash is broken"; it also probed only one bash candidate and never offered Python the shell the installer was already running under | **HIGH — refused to install on a healthy WSL box** | `$PY` unquoted (as every other call site already had it); multi-candidate probe that hands Python the installer's own bash first; explicit WSL-shell + Windows-Python mismatch message |
| **the suite spawned bare `bash`, which on Windows resolves to the System32 WSL relay** | **HIGH — a real install reported 130 failures, every gate fine, none reachable** | probe that proves bash runs a command before using it (the `rt_pick_py` treatment); installers now pin `RATCHET_BASH`; host check fails before install; regression test added |
| escalation refusal records accumulated forever (never swept by `archive` or `prune`) | LOW — ~30k tiny files after 500 runs; violates the harness's own `artifacts-outlive-their-run` lesson | `archive` now rotates them into the run's archive dir as evidence; the single-use ledger stays live |
| deleting a temp file outside the repo was refused | LOW — a control layer you cannot use is one agents route around | recognised temp roots exempt; arbitrary absolute paths still refused |
| law block was not delimited in the 12 seats | LOW — the anti-drift comparator could not run | `<!-- LAWBLOCK:BEGIN/END -->` in every seat |
| two seeded lesson names failed the naming doctrine's own regex | LOW | renamed before first filing (a name is permanent after that) |

## Honest limitations

1. **`install.ps1` has never been executed on Windows.** No PowerShell in the build sandbox.
   It is structurally validated (balanced blocks, no BOM, LF-safe writes, 5.1-compatible
   constructs) and written against the known 5.1 traps, but it needs one real run before you
   trust it. `install.sh` under Git-Bash is the verified Windows path today.
2. **GitHub only.** The `gh` CLI, PR flow and branch protection are assumed. Other forges
   need work in `guard.sh`'s ship-flow section.
3. **`gh` was absent in the sandbox**, so the ship flow's live merge path is unexercised.
   The refusals around it are tested; the success path is not.
4. **7 skipped tests**, each skipping loudly rather than passing falsely: 2 need a TTY (a minted
   approval, a disclosure record), 2 cover an unimplemented `COMMIT_SCOPE_LINES` declaration rule,
   1 covers evidence-path auditing this build's `check_done.py` does not implement, and 2 are
   test-harness gaps (`rt_work_seconds` not printing under the harness's own probe — its behaviour
   was verified by hand instead: 5000s elapsed with 4000s idle folds to 1000s of work — and hooklib
   exposing no `rt_is_compound`). None of the 7 is Windows-conditional; run the suite on Windows
   before assuming that stays true.
5. **The consent record is a record, not a control.** Branch protection is the control. The
   harness says this in three places because the source pipeline learned it the hard way.
6. **Nothing here has run a real milestone yet.** The pipeline is proven in its predecessor;
   this generic build is proven only against its own test suite and two scratch installs.

## First-run advice

Do not point this at important work on day one. Install it, fill `SPEC.md` and
`MILESTONES.md` with a deliberately small M0 (two WIN rows), and run that. You want to see
the gates fire, a Decision Card arrive, and a checkpoint block — cheaply — before a real
milestone depends on them.

## Footprint (measured, not estimated)

| | |
|---|---|
| self-test | 180 tests, 173 pass, 0 fail, 7 skip (grows with the suite; re-run for current numbers) |
| install size | ~1.2 MB, of which `test_hooks.py` is 172 KB (13%) |
| `guard.sh` per Bash tool call | ~64 ms |
| `scope-guard.sh` per Edit/Write | ~58 ms |
| `session-start.sh` (once per session) | ~1.5 s, incl. a 0.6 s `--smoke` self-test |
| full self-test (install verification only) | ~100 s |

**Growth per run.** `.pipeline/` is run-scoped: `archive` rotates the events log, the manifest,
the journal, the checkpoints and (as of this fix) the refusal records into
`.pipeline/archive/<milestone>-<epoch>/`, so the live directory returns to roughly empty at every
gate closure. Refusal records are ~67 bytes and dedupe by content-derived id, so an identical
refusal repeated fifty times still costs one file.

The one thing that grows on purpose is `.agent-development/` — one retro per run, tracked in git,
never pruned. That is the point of it. `ACTIVE-LESSONS.md` is hard-capped at 100 lines precisely
because it is the only part of the corpus that is read on every future run, so its length is a cost
paid forever; the retros themselves are read only when someone goes looking.

`du` overstates all of this: 53 escalation records show as 220 KB of 4 KB blocks and are 18.5 KB of
actual content.

## If the suite reports mass failures on Windows

Look at one failure's `stderr` before anything else. If it says:

    WSL ... ERROR: CreateProcessCommon:800: execvpe(/bin/bash) failed

then no gate is broken. Python resolved `bash` to `C:\Windows\System32\bash.exe` — the
WSL *relay* — which shadows Git-Bash on PATH and dies before the hook runs when no WSL distro
is installed. Every test then fails for the same unrelated reason.

Ratchet 1.0.0 probes for a bash that actually runs a command, prefers Git-Bash, and prints its
choice in the suite's first line (`ratchet self-test: bash=... python=...`). Both installers now
pin `RATCHET_BASH` to the interpreter they verified, and `install.sh` refuses to install if Python
cannot spawn a working bash at all. To override by hand:

    set RATCHET_BASH=C:\Program Files\Git\bin\bash.exe          (Windows)
    RATCHET_BASH=/usr/bin/bash ./install.sh ...              (WSL / Linux / macOS)

**Running under WSL?** Stay entirely inside it: clone into `~/`, not `/mnt/c/`, and use the
distro's own `python3` and `git`. A WSL shell driving a *Windows* Python is the one configuration
that cannot work — the two do not share a filesystem, so no single bash path satisfies both and
every error message names a file that really exists on the other side. `install.sh` now detects
that pairing and refuses with an explanation rather than a generic bash complaint.

**A red verification no longer records a postcondition baseline.** Baselining from a red run
would record that day's breakage as the host's normal state, after which the postcondition check
passes while the control layer is broken — a check that looks green being strictly worse than no
check at all.


---

# 1.1.0 — what changed

**New: `ratchet-dependencies.sh` / `.ps1`.** Detects and installs what the host check requires
(bash 4+, git, jq, a working python3, gh) across apt / dnf / yum / pacman / apk / brew / winget /
choco, plus optional stack tools. `--check` reports and changes nothing; `--dry-run` prints the
plan; nothing is sudo'd without showing the command first. It refuses to curl-pipe an installer,
refuses to pip into a PEP-668 interpreter, and detects the Windows Store python stub by path.

**New: `ratchet-update.sh` / `.ps1` + `.claude/doctrine/UPGRADING.md`.** Mid-project scaffold upgrades.
Every path is classified HARNESS (replaced), USER (never touched), or MERGED (settings.json only) —
and the classifier's default is USER, so an unrecognised path is never touched. It detects harness
files you edited locally against a checksum baseline, preserves them as `.local-<timestamp>`,
backs up `.claude/` with a one-command rollback, refuses to run mid-run (the second half of a run
would be judged by different rules than the first), and runs the suite afterwards without
auto-rolling-back a failure. `UPGRADING.md` covers the agent-driven path: the control layer is
Tier 2b, so a project's own pipeline changes go through the supervisor-changeset pattern and are
proposed upstream, not patched locally.

**Redesigned installer UI.** Phased progress (`[3/7]`), aligned status columns, box-drawn summary,
spinners on the two slow steps. Degrades to ASCII on legacy code pages, drops colour under
`NO_COLOR` / non-TTY / `TERM=dumb`, clamps to terminal width, and emits zero escape bytes when
redirected. New flags: `--quiet`, `--no-color`, `--ascii`.

**`.context/` is now bare bones (2604 → 2107 lines).** `SPEC.md` and `MILESTONES.md` ship as
~15-line placeholders carrying `<!-- ratchet:unwritten -->`; `CONVENTIONS.md` is gone. In their
place is **`.claude/doctrine/TEMPLATE.md`** (395 lines): the one structural guide an agent reads to write
the project's real contracts — taxonomy, AV register, WIN-row spec, naming doctrine, every frozen
format, and one minimal two-row example. `check_done.py` detects the unwritten marker and fails
with an actionable message instead of passing vacuously on a file with no WIN rows.

## Defects found and fixed in 1.1.0

| defect | severity | fix |
|---|---|---|
| **the suite armed a phantom run in the repo under test**: `sh()` set `cwd` to the fixture, but sourcing `ratchet.config.sh` cds to REPO_ROOT by design, so every relative path afterwards escaped into the real project — writing `.pipeline/run-active` there | **HIGH — a phantom active run changes how every gate behaves, and it blocked the updater** | the helper returns to the fixture after sourcing; also resolves the long-standing `rt_work_seconds` skip, which was the same escape |
| `install.sh` never wrote `.ratchet-version` / `.ratchet-manifest` | MEDIUM — the first update could not tell your edits from upstream changes, so everything read as UNVERIFIED | install records both at the end of a successful install |
| host-check failure told you to "fix the FAIL lines" with no tool to do it | LOW | points at `ratchet-dependencies.sh --check` |
| first-run instructions told the agent to read SPEC/MILESTONES, which are now placeholders | LOW | tells it to read `TEMPLATE.md`, interview you, and invent nothing |


---

# 1.2.0 — two owner questions, both correct

## 1. `.context/` now holds only what you own

The complaint was fair: `.context/` was supposed to be *your project's contracts*, and it still had
seven files including a 912-line orchestrator manual. Those four documents ship identically to every
project and are replaced wholesale by the updater — they were harness doctrine sitting in the
human's folder, which blurs the very ownership partition the harness is built on.

Moved to `.claude/doctrine/` (the control layer: harness-owned, agent-unwritable, replaced on
update): `CLAUDE.md`, `PIPELINE.md`, `TEMPLATE.md`, `UPGRADING.md`.

`.context/` is now exactly three files, and every one of them is yours:

| file | what it is |
|---|---|
| `SPEC.md` | placeholder until written — your requirement ids |
| `MILESTONES.md` | placeholder until written — your WIN rows |
| `DECISIONS.md` | header + format, fills as you decide things |

~167 path references were repointed. The root `CLAUDE.md` pointer is now
`@.claude/doctrine/CLAUDE.md`, doctrine is copied unconditionally (like hooks) rather than
if-absent, and the updater classifies `.claude/doctrine/**` as HARNESS — verified: a local edit to
`PIPELINE.md` is reported and preserved, while `SPEC.md` is untouched.

## 2. Install verification: 230s -> 28s

900 was a *ceiling*, never the runtime — but the runtime was ~95s and the installer ran the suite
**twice** (once to verify, once to record the postcondition baseline), so a scaffolding step really
was costing about four minutes. Two fixes:

- **The baseline no longer re-runs anything.** It records "which items currently fail". After a
  green run that set is provably empty, so it is written directly. That alone halved install time.
- **A `--quick` verification tier, now the default.** 50 tests in ~25s: every security wall
  (write-effect-beats-read-carve-out, secrets, ship flow, Tier 2b, approval single-use) and every
  meta-invariant that catches a botched install (rule classification, deny-partition consistency,
  the 12 law copies, genericity, the bash probe). `--verify full` runs all 177 in ~95s;
  `--verify smoke` is ~1s; `--verify none` skips it.

Run `--verify full` once, and after any control-layer change. The quick tier is chosen so that a
scaffolding step nobody waits for does not become a scaffolding step people skip.

**Also fixed:** passing a bare class name to `test_hooks.py` silently ran the entire suite instead
of filtering, which made per-class timing impossible. A bare positional now filters like `-k`.

| measurement | 1.1.0 | 1.2.0 |
|---|---|---|
| install wall time | ~230s | **28s** |
| `.context/` files / lines | 7 / 2107 | **3 / ~125** |
| default verification | full, 177 tests | quick, 50 tests |


---

# 1.2.1 — the Windows failure was a real bug, and the report was useless

## The bug: case-insensitive paths

`rt_repo_rel_var` stripped the repo root off a path with an EXACT string compare. Windows
filesystems are case-insensitive, and the four sources of a path here — `CLAUDE_PROJECT_DIR`,
`git rev-parse`, `BASH_SOURCE`, and the tool payload — do not agree on casing for the same
directory. When they disagreed the strip silently failed, the path stayed ABSOLUTE, and every
downstream comparison misfired.

Two consequences, and the second is the serious one:

- **Fail closed, visible:** `.pipeline/notes.md` no longer matched its own exemption, so the agent
  was refused its own scratch directory. This is what the failing tests reported.
- **Fail OPEN, invisible:** `.context/SPEC.md` no longer matched the governing corpus either. A
  Tier 2b path the guard cannot recognise is a Tier 2b path the guard cannot protect. Nothing
  reported this, because nothing was blocked.

Fixed: on Windows-form paths the prefix compare is case-insensitive, and the slice is taken from
the original string so real casing survives. POSIX paths still compare exactly — `/home/me/Repo`
and `/home/me/repo` are genuinely different directories and folding them would be a new bug.
Regression tests cover both directions, including the fail-open case.

## Failing gracefully

The install ran for 414 seconds and then printed a wall of tracebacks. Three fixes:

- **`--max-seconds`**: the run stops BETWEEN tests when the budget is spent. Never inside one —
  aborting mid-setUp reports tests that never ran as errors, and a self-test that lies about the
  gates is worse than no self-test. The installer sets 120s on POSIX, 420s on Windows.
- **`--brief`**: failures are grouped by test class with the first two examples and a LIKELY CAUSE
  line, instead of raw tracebacks. It recognises the three common shapes: a missing bash (host, not
  gates), the scratch-directory refusal (path normalisation, not policy), and failures spread
  across most of the suite (one shared dependency, not many broken gates).
- **Windows expectations up front**: `--verify full` on Windows warns that it takes ~25 minutes and
  that this is process-spawn cost, not the gates.

## Why Windows is 16x slower

Measured: `--quick` is 25s on Linux and 414s under Git-Bash. The suite is almost entirely process
spawns (each test drives real hooks through real bash), and Windows process creation is roughly an
order of magnitude more expensive, before antivirus. Nothing is wrong; the work is real. The
budget exists so you find that out in two minutes instead of seven.

## Also fixed

- A bare positional passed to `test_hooks.py` (e.g. `--max-seconds 8`) was swallowed as a test-name
  pattern, silently running zero tests. Flag values are now skipped.
- Subtest failures reported as `_SubTest` in the brief report instead of their real class.
