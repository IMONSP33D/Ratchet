#!/usr/bin/env python3
# =============================================================================
# check_narrative.py --- Ratchet narrative budget + naming doctrine validator.
#
# CONTRACT (this file owns these behaviours; readers: check_done.py check 5 and
# check 12, plus test_hooks.py's naming round-trip test):
#
#   * The ONE-HOME RULE (CONTRACT.md token doctrine 8): a decision's story lives
#     in exactly one place --- the archive body
#     `.context/archive/decisions/DEC-nnn-full.md` --- and its hot entry in
#     `.context/DECISIONS.md`. EVERY other site that cites a DEC id carries one
#     sentence plus the id and nothing more.
#   * Word / line caps from `ratchet.config.sh` (CONTRACT.md 2.1). This script
#     NEVER hardcodes a cap default: the shell config is the single source of
#     truth and an unset cap is an environment error (exit 3), not a guess.
#   * `--validate-name` implements CONTRACT.md 6 with EXACTLY the same rules as
#     `rt_name_valid` in hooklib.sh. If you change one, change the other; the
#     round-trip test in test_hooks.py compares them on a shared fixture list.
#
# Stdlib only. utf-8 on every open. No project nouns.
#
# EXIT CODES
#   0  no violations (or: name is valid, in --validate-name mode)
#   1  at least one violation (or: name is invalid)
#   2  usage error
#   3  environment error (config not found / required cap unset / no repo root)
# =============================================================================
"""Narrative budget and naming-doctrine checker for the Ratchet harness.

Modes:
  (default)            scan the repo's narrative artifacts, report violations
  --validate-name N    validate one or more names against CONTRACT.md 6
  --names-file F       validate a newline-delimited list of names
  --list               list the check names this script can emit
  --selftest           build a temp fixture and prove a PASS and a FAIL outcome
"""

import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile

# ---------------------------------------------------------------------------
# Check registry --- every name this script can emit, with a one-line meaning.
# check_done.py maps these onto its numbered checks:
#   check 5  (rationale-caps) <- rationale-cap-fixed, rationale-cap-accepted,
#                                accepted-missing-dec
#   check 12 (narrative)      <- everything else
# ---------------------------------------------------------------------------
CHECKS = [
    ("rationale-cap-fixed", "FIXED finding rationale over CAP_RATIONALE_FIXED words"),
    ("rationale-cap-accepted",
     "ACCEPTED/DEFERRED/WAIVED rationale over CAP_RATIONALE_ACCEPTED words"),
    ("accepted-missing-dec",
     "ACCEPTED/DEFERRED/WAIVED row with no DEC id (the rationale IS the artifact)"),
    ("one-home-rule", "a decision's story told outside its one home"),
    ("probe-in-cell", "probe transcript / command output pasted into a ledger cell"),
    ("decision-word-cap", "DECISIONS entry Decision field over 120 words"),
    ("checkpoint-summary-cap", "jump summary over CAP_CHECKPOINT_SUMMARY words"),
    ("clear-verdict-cap", "clear-reviewer verdict over CAP_CLEAR_VERDICT words"),
    ("recap-word-cap", "recap over CAP_RECAP_WORDS words"),
    ("retro-line-cap", "run retro over CAP_RETRO_LINES lines"),
    ("active-lessons-line-cap", "ACTIVE-LESSONS over CAP_ACTIVE_LESSONS_LINES lines"),
]
CHECK_NAMES = [c[0] for c in CHECKS]

# The Decision-field cap is frozen in CONTRACT.md 7.3 as prose ("<=120 words"),
# not as a config variable, so it lives here rather than in ratchet.config.sh.
DECISION_FIELD_WORD_CAP = 120

CONFIG_KEYS = [
    "REPO_ROOT", "PIPELINE_DIR", "CONTEXT_DIR", "DEV_DIR", "CHECKPOINTS_DIR",
    "FINDINGS", "AMENDMENTS", "CONTEXT_LIVE", "RUN_JOURNAL", "RECAP",
    "ACTIVE_LESSONS", "PENDING_ACTIONS",
    "CAP_RATIONALE_FIXED", "CAP_RATIONALE_ACCEPTED", "CAP_CHECKPOINT_SUMMARY",
    "CAP_CLEAR_VERDICT", "CAP_RECAP_WORDS", "CAP_RETRO_LINES",
    "CAP_ACTIVE_LESSONS_LINES",
]


class EnvError(Exception):
    """Environment is not fit to run the check --- exit 3, fail closed."""


# ---------------------------------------------------------------------------
# Config access --- source the shell config once and read the values back.
# Defaults are NOT duplicated here on purpose (single source of truth).
# ---------------------------------------------------------------------------
_EXTRACT = (
    'set -u; cfg="$1"; shift; '
    '. "$cfg" >/dev/null 2>&1 || exit 9; '
    'for v in "$@"; do eval "val=\\${$v-}"; printf "%s\\t%s\\n" "$v" "$val"; done'
)


def find_hooks_dir(start=None):
    here = os.path.dirname(os.path.abspath(start or __file__))
    return here


def find_repo_root(hooks_dir):
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and os.path.isdir(env):
        return os.path.abspath(env)
    # .claude/hooks/<this file>  ->  repo root is two levels up
    cand = os.path.abspath(os.path.join(hooks_dir, "..", ".."))
    if os.path.isdir(os.path.join(cand, ".claude")):
        return cand
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=20)
        if out.returncode == 0 and out.stdout.strip():
            return os.path.abspath(out.stdout.strip())
    except Exception:
        pass
    return cand


def load_config(hooks_dir, keys):
    cfg = os.path.join(hooks_dir, "ratchet.config.sh")
    if not os.path.isfile(cfg):
        raise EnvError("ratchet.config.sh not found at %s (fail closed)" % cfg)
    if not shutil.which("bash"):
        raise EnvError("bash not on PATH; cannot read config (fail closed)")
    proc = subprocess.run(["bash", "-c", _EXTRACT, "bash", cfg] + list(keys),
                          capture_output=True, text=True, timeout=60)
    if proc.returncode == 9:
        raise EnvError("could not source %s: %s" % (cfg, proc.stderr.strip()))
    if proc.returncode != 0:
        raise EnvError("config extraction failed (%d): %s"
                       % (proc.returncode, proc.stderr.strip()))
    values = {}
    for line in proc.stdout.replace("\r", "").split("\n"):
        if not line or "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        values[k] = v
    return values


class Ctx(object):
    """Resolved paths + caps for one run of the checker."""

    def __init__(self, hooks_dir, repo_root, cfg):
        self.hooks_dir = hooks_dir
        self.root = repo_root
        self.cfg = cfg

    def path(self, key):
        v = self.cfg.get(key, "")
        if not v:
            return None
        return v if os.path.isabs(v) else os.path.join(self.root, v)

    def cap(self, key):
        v = self.cfg.get(key, "").strip()
        if not v:
            raise EnvError("required cap %s is unset in ratchet.config.sh" % key)
        try:
            return int(v)
        except ValueError:
            raise EnvError("cap %s is not an integer: %r" % (key, v))


def make_ctx(repo_root=None, hooks_dir=None):
    hd = hooks_dir or find_hooks_dir()
    root = repo_root or find_repo_root(hd)
    if hooks_dir is None and repo_root is not None:
        cand = os.path.join(repo_root, ".claude", "hooks")
        if os.path.isfile(os.path.join(cand, "ratchet.config.sh")):
            hd = cand
    env_root = dict(os.environ)
    env_root.setdefault("CLAUDE_PROJECT_DIR", root)
    old = os.environ.get("CLAUDE_PROJECT_DIR")
    os.environ["CLAUDE_PROJECT_DIR"] = root
    try:
        cfg = load_config(hd, CONFIG_KEYS)
    finally:
        if old is None:
            os.environ.pop("CLAUDE_PROJECT_DIR", None)
        else:
            os.environ["CLAUDE_PROJECT_DIR"] = old
    cfg_root = cfg.get("REPO_ROOT", "").strip()
    if cfg_root and os.path.isdir(cfg_root) and repo_root is None:
        root = os.path.abspath(cfg_root)
    return Ctx(hd, root, cfg)


# ---------------------------------------------------------------------------
# Small IO / text helpers
# ---------------------------------------------------------------------------
def read_text(path):
    """Read utf-8, tolerate CRLF from Windows editors. '' when unreadable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().replace("\r\n", "\n").replace("\r", "\n")
    except (IOError, OSError):
        return ""


def word_count(text):
    return len([t for t in re.split(r"\s+", (text or "").strip()) if t])


def sentence_count(text):
    """Terminators followed by whitespace or end-of-string. 0 -> treat as 1."""
    n = len(re.findall(r"[.!?](?:\s|$)", (text or "").strip()))
    return n if n else 1


def rel(ctx, path):
    try:
        return os.path.relpath(path, ctx.root).replace(os.sep, "/")
    except ValueError:
        return path


# ---------------------------------------------------------------------------
# findings.md ledger parser (format frozen in CONTRACT.md 7.4)
#   | name | source | severity as filed | file:line | finding | disposition |
#   | rationale | DEC |
# check_done.py carries the same parser; both are derived from this comment.
# ---------------------------------------------------------------------------
LEDGER_COLUMNS = ["name", "source", "severity as filed", "file:line",
                  "finding", "disposition", "rationale", "DEC"]
DISPOSITIONS = ["FIXED", "ACCEPTED", "DEFERRED", "WAIVED"]


def split_row(line):
    s = line.strip()
    if not s.startswith("|"):
        return None
    s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def is_separator_row(cells):
    return bool(cells) and all(re.match(r"^:?-{2,}:?$", c or "-") for c in cells)


def parse_ledger(text):
    """Return (header_cells_or_None, [(lineno, cells)], header_lineno)."""
    header = None
    header_lineno = 0
    rows = []
    for i, line in enumerate(text.split("\n"), start=1):
        cells = split_row(line)
        if cells is None:
            continue
        if header is None:
            norm = [c.strip().lower() for c in cells]
            if norm and norm[0] in ("name", "id"):
                header = cells
                header_lineno = i
            continue
        if is_separator_row(cells):
            continue
        if len(cells) < 2:
            continue
        rows.append((i, cells))
    return header, rows, header_lineno


def cell(cells, header, name):
    """Column lookup BY NAME (never by position)."""
    lower = [h.strip().lower() for h in header]
    key = name.strip().lower()
    if key not in lower:
        return ""
    idx = lower.index(key)
    return cells[idx] if idx < len(cells) else ""


# ---------------------------------------------------------------------------
# Naming doctrine --- CONTRACT.md 6. MUST match hooklib.sh rt_name_valid.
# ---------------------------------------------------------------------------
NAME_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$")
STEP_RE = re.compile(r"^(.*)-([0-9]+)$")
GENERIC_NAMES = [
    "fix-issue", "fix-bug", "misc-problem", "update-thing", "general-fix",
    "various-fixes", "minor-issue", "small-fix", "quick-fix", "todo-item",
]
GENERIC_PREFIX_RE = re.compile(
    r"^(fix|update|change|misc|various|general|temp|new|old)-")


def validate_name(name):
    """Return (True, '') or (False, '<reason-token>').

    Reason tokens (stable; hooklib.sh emits the same set):
      empty, not-kebab-case, generic-name, generic-prefix
    """
    if name is None:
        return False, "empty"
    n = name.strip()
    if not n:
        return False, "empty"
    base = n
    m = STEP_RE.match(n)
    if m and not NAME_RE.match(n):
        base = m.group(1)
    if not NAME_RE.match(n) and not (m and NAME_RE.match(m.group(1))):
        return False, "not-kebab-case"
    if m and NAME_RE.match(m.group(1)):
        base = m.group(1)
    for candidate in {n, base}:
        if candidate in GENERIC_NAMES:
            return False, "generic-name"
    for candidate in {n, base}:
        if GENERIC_PREFIX_RE.match(candidate):
            return False, "generic-prefix"
    return True, ""


# ---------------------------------------------------------------------------
# Violations
# ---------------------------------------------------------------------------
def viol(check, site, detail, name=""):
    return {"check": check, "site": site, "detail": detail, "name": name}


PROBE_MARKERS = [
    ("$ ", "shell prompt"),
    ("PS>", "shell prompt"),
    (">>>", "interpreter prompt"),
    ("Traceback", "stack trace"),
    ("+++ ", "diff hunk"),
    ("--- ", "diff hunk"),
    ("@@", "diff hunk"),
    ("```", "code fence"),
    ("<br>", "embedded newline"),
    ("\\n", "escaped newline"),
    ("PASSED", "test-runner output"),
    ("FAILED", "test-runner output"),
    ("=====", "test-runner banner"),
]


def check_findings(ctx):
    out = []
    fpath = ctx.path("FINDINGS")
    if not fpath or not os.path.isfile(fpath):
        return out
    text = read_text(fpath)
    header, rows, _ = parse_ledger(text)
    if header is None:
        return out  # structural complaint belongs to check_done check 4
    cap_fixed = ctx.cap("CAP_RATIONALE_FIXED")
    cap_acc = ctx.cap("CAP_RATIONALE_ACCEPTED")
    for lineno, cells in rows:
        site = "%s:%d" % (rel(ctx, fpath), lineno)
        name = cell(cells, header, "name")
        disp = cell(cells, header, "disposition").upper()
        rationale = cell(cells, header, "rationale")
        dec = cell(cells, header, "DEC")
        wc = word_count(rationale)
        if disp == "FIXED":
            if wc > cap_fixed:
                out.append(viol("rationale-cap-fixed", site,
                                "FIXED rationale is %d words (cap %d)" % (wc, cap_fixed),
                                name))
        elif disp in ("ACCEPTED", "DEFERRED", "WAIVED"):
            if wc > cap_acc:
                out.append(viol("rationale-cap-accepted", site,
                                "%s rationale is %d words (cap %d)" % (disp, wc, cap_acc),
                                name))
            if not re.search(r"DEC-\d{3,}", dec or ""):
                out.append(viol("accepted-missing-dec", site,
                                "%s row cites no DEC id; the rationale is the only "
                                "record of why a real defect ships" % disp, name))
        # probe transcripts must never appear in a ledger cell
        for c_name in ("finding", "rationale"):
            val = cell(cells, header, c_name)
            for marker, why in PROBE_MARKERS:
                if marker in val:
                    out.append(viol("probe-in-cell", site,
                                    "%s cell contains %s (%r); paste the transcript "
                                    "under docs/evidence and cite the path"
                                    % (c_name, why, marker), name))
                    break
    return out


# --- one-home rule --------------------------------------------------------
DEC_RE = re.compile(r"DEC-\d{3,}")


def one_home_sites(ctx):
    """Files that may CITE a decision but must never re-tell it."""
    sites = []
    for key in ("FINDINGS", "AMENDMENTS", "CONTEXT_LIVE", "RUN_JOURNAL",
                "RECAP", "ACTIVE_LESSONS", "PENDING_ACTIONS"):
        p = ctx.path(key)
        if p and os.path.isfile(p):
            sites.append(p)
    pipeline = ctx.path("PIPELINE_DIR")
    if pipeline and os.path.isdir(pipeline):
        for fn in sorted(os.listdir(pipeline)):
            if fn.endswith(".md") and fn.startswith("ship-report"):
                sites.append(os.path.join(pipeline, fn))
    cp = ctx.path("CHECKPOINTS_DIR")
    if cp and os.path.isdir(cp):
        for fn in sorted(os.listdir(cp)):
            if fn.endswith(".md"):
                sites.append(os.path.join(cp, fn))
    dev = ctx.path("DEV_DIR")
    if dev:
        runs = os.path.join(dev, "runs")
        if os.path.isdir(runs):
            for fn in sorted(os.listdir(runs)):
                if fn.endswith(".md"):
                    sites.append(os.path.join(runs, fn))
    seen, uniq = set(), []
    for p in sites:
        ap = os.path.abspath(p)
        if ap not in seen:
            seen.add(ap)
            uniq.append(ap)
    return uniq


def check_one_home(ctx):
    """A citing site carries ONE sentence plus the id, and nothing more.

    The per-site cap reuses CAP_RATIONALE_FIXED (a pointer-sized budget); no new
    config variable is invented for it.
    """
    out = []
    cap = ctx.cap("CAP_RATIONALE_FIXED")
    for path in one_home_sites(ctx):
        text = read_text(path)
        for i, line in enumerate(text.split("\n"), start=1):
            ids = DEC_RE.findall(line)
            if not ids:
                continue
            cells = split_row(line)
            if cells:
                chunks = [c for c in cells if DEC_RE.search(c)]
            else:
                chunks = [line]
            for chunk in chunks:
                stripped = re.sub(r"^[\s>*#-]+", "", chunk).strip()
                wc = word_count(stripped)
                sc = sentence_count(stripped)
                if wc > cap or sc > 1:
                    out.append(viol(
                        "one-home-rule", "%s:%d" % (rel(ctx, path), i),
                        "%s retold in %d words / %d sentences (cap: 1 sentence, "
                        "%d words); the story's one home is "
                        ".context/archive/decisions/%s-full.md"
                        % (ids[0], wc, sc, cap, ids[0]), ids[0]))
                    break
    return out


def check_decisions(ctx):
    """DECISIONS.md hot entries: Decision field <= 120 words (CONTRACT.md 7.3)."""
    out = []
    cdir = ctx.path("CONTEXT_DIR")
    if not cdir:
        return out
    path = os.path.join(cdir, "DECISIONS.md")
    if not os.path.isfile(path):
        return out
    text = read_text(path)
    lines = text.split("\n")
    current, start = None, 0
    buf = []

    def flush(entry, entry_line, body):
        if not entry:
            return
        joined = "\n".join(body)
        m = re.search(r"\*\*Decision\.\*\*(.*?)(?=\n\*\*|\Z)", joined, re.S)
        if not m:
            return
        wc = word_count(m.group(1))
        if wc > DECISION_FIELD_WORD_CAP:
            out.append(viol("decision-word-cap",
                            "%s:%d" % (rel(ctx, path), entry_line),
                            "Decision field is %d words (cap %d); the body belongs "
                            "in the archive" % (wc, DECISION_FIELD_WORD_CAP), entry))

    for i, line in enumerate(lines, start=1):
        m = re.match(r"^##\s+(DEC-\d{3,})", line)
        if m:
            flush(current, start, buf)
            current, start, buf = m.group(1), i, []
        elif current:
            buf.append(line)
    flush(current, start, buf)
    return out


def check_length_caps(ctx):
    out = []
    # checkpoint jump summaries + clear verdicts
    cp = ctx.path("CHECKPOINTS_DIR")
    if cp and os.path.isdir(cp):
        cap_jump = ctx.cap("CAP_CHECKPOINT_SUMMARY")
        cap_clear = ctx.cap("CAP_CLEAR_VERDICT")
        for fn in sorted(os.listdir(cp)):
            p = os.path.join(cp, fn)
            if not os.path.isfile(p):
                continue
            if fn.endswith("-jump.md"):
                wc = word_count(read_text(p))
                if wc > cap_jump:
                    out.append(viol("checkpoint-summary-cap", rel(ctx, p),
                                    "jump summary is %d words (cap %d)"
                                    % (wc, cap_jump), fn))
            elif fn.endswith("-clear.md"):
                wc = word_count(read_text(p))
                if wc > cap_clear:
                    out.append(viol("clear-verdict-cap", rel(ctx, p),
                                    "clear verdict is %d words (cap %d)"
                                    % (wc, cap_clear), fn))
    # recap
    recap = ctx.path("RECAP")
    if recap and os.path.isfile(recap):
        cap = ctx.cap("CAP_RECAP_WORDS")
        wc = word_count(read_text(recap))
        if wc > cap:
            out.append(viol("recap-word-cap", rel(ctx, recap),
                            "recap is %d words (cap %d)" % (wc, cap)))
    # retro docs
    dev = ctx.path("DEV_DIR")
    if dev and os.path.isdir(os.path.join(dev, "runs")):
        cap = ctx.cap("CAP_RETRO_LINES")
        runs = os.path.join(dev, "runs")
        for fn in sorted(os.listdir(runs)):
            if not fn.endswith(".md") or fn.startswith("_"):
                continue
            p = os.path.join(runs, fn)
            n = len([l for l in read_text(p).split("\n")])
            if n > cap:
                out.append(viol("retro-line-cap", rel(ctx, p),
                                "retro is %d lines (cap %d)" % (n, cap), fn))
    # active lessons
    al = ctx.path("ACTIVE_LESSONS")
    if al and os.path.isfile(al):
        cap = ctx.cap("CAP_ACTIVE_LESSONS_LINES")
        n = len(read_text(al).split("\n"))
        if n > cap:
            out.append(viol("active-lessons-line-cap", rel(ctx, al),
                            "ACTIVE-LESSONS is %d lines (cap %d); consolidate"
                            % (n, cap)))
    return out


def scan(ctx, only=None):
    violations = []
    violations.extend(check_findings(ctx))
    violations.extend(check_one_home(ctx))
    violations.extend(check_decisions(ctx))
    violations.extend(check_length_caps(ctx))
    if only:
        violations = [v for v in violations if v["check"] == only]
    return violations


# ---------------------------------------------------------------------------
# Selftest --- builds a fixture and asserts BOTH a clean pass and a failure.
# ---------------------------------------------------------------------------
FIXTURE_CONFIG = """#!/usr/bin/env bash
# Selftest fixture config. Deliberately NOT the shipped defaults --- distinctive
# values prove the checker reads the config instead of guessing.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
PIPELINE_DIR=".pipeline"
CONTEXT_DIR=".context"
DEV_DIR=".agent-development"
CHECKPOINTS_DIR=".pipeline/checkpoints"
FINDINGS=".pipeline/findings.md"
AMENDMENTS=".pipeline/manifest-amendments.txt"
CONTEXT_LIVE=".pipeline/context-live.md"
RUN_JOURNAL=".pipeline/run-journal.md"
RECAP=".pipeline/recap.md"
ACTIVE_LESSONS=".agent-development/ACTIVE-LESSONS.md"
PENDING_ACTIONS=".agent-development/PENDING-HUMAN-ACTIONS.md"
CAP_RATIONALE_FIXED=7
CAP_RATIONALE_ACCEPTED=12
CAP_CHECKPOINT_SUMMARY=20
CAP_CLEAR_VERDICT=15
CAP_RECAP_WORDS=25
CAP_RETRO_LINES=6
CAP_ACTIVE_LESSONS_LINES=5
"""

LEDGER_HEADER = ("| name | source | severity as filed | file:line | finding | "
                 "disposition | rationale | DEC |\n"
                 "|---|---|---|---|---|---|---|---|\n")


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def build_fixture(root, clean=True):
    _write(os.path.join(root, ".claude", "hooks", "ratchet.config.sh"), FIXTURE_CONFIG)
    if clean:
        ledger = LEDGER_HEADER + (
            "| gate-blames-wrong-actor | reviewer | HIGH | guard.sh:12 | wrong actor "
            "blamed | FIXED | fixed in guard | DEC-004 |\n"
            "| ledger-row-count-drifts | security | MEDIUM | check_done.py:9 | count "
            "drifts | ACCEPTED | accepted per DEC-005 | DEC-005 |\n")
        _write(os.path.join(root, ".pipeline", "findings.md"), ledger)
        _write(os.path.join(root, ".pipeline", "context-live.md"),
               "# Live\n\nScope widened per DEC-004.\n")
        _write(os.path.join(root, ".agent-development", "ACTIVE-LESSONS.md"),
               "# Lessons\n\n## gate-blames-wrong-actor\nMUST-FIX\n")
    else:
        ledger = LEDGER_HEADER + (
            # FIXED rationale over the 7-word fixture cap
            "| gate-blames-wrong-actor | reviewer | HIGH | guard.sh:12 | wrong actor "
            "blamed | FIXED | this rationale is deliberately far too long for the "
            "fixed cap set in the fixture config | DEC-004 |\n"
            # ACCEPTED with no DEC id
            "| ledger-row-count-drifts | security | MEDIUM | check_done.py:9 | count "
            "drifts | ACCEPTED | accepted for now |  |\n"
            # probe transcript in a cell
            "| probe-pasted-in-cell | reviewer | LOW | run.sh:1 | broke | FIXED | "
            "$ pytest -q FAILED | DEC-004 |\n")
        _write(os.path.join(root, ".pipeline", "findings.md"), ledger)
        # one-home violation: a whole story retold outside the archive
        _write(os.path.join(root, ".pipeline", "context-live.md"),
               "# Live\n\nDEC-004 was taken because the gate blamed the wrong actor "
               "for seven dispatches in a row. We considered three alternatives and "
               "rejected two of them. The third became the rule.\n")
        _write(os.path.join(root, ".agent-development", "ACTIVE-LESSONS.md"),
               "# Lessons\n\n## gate-blames-wrong-actor\nMUST-FIX\nline\nline\nline\n"
               "line\nline\n")


def selftest():
    ok = True
    tmp = tempfile.mkdtemp(prefix="ratchet-narrative-")
    try:
        # --- names ---------------------------------------------------------
        good = ["gate-blames-wrong-actor", "harness-adjustment-1",
                "ledger-row-count-drifts", "a-b", "one-two-three-four-five"]
        bad = ["fix-issue", "quick-fix", "todo-item", "Issue-3", "single",
               "one-two-three-four-five-six", "misc-problem", "new-thing",
               "trailing-", "has_underscore", ""]
        for n in good:
            v, why = validate_name(n)
            if not v:
                print("SELFTEST FAIL: %r should be valid (%s)" % (n, why))
                ok = False
        for n in bad:
            v, _ = validate_name(n)
            if v:
                print("SELFTEST FAIL: %r should be invalid" % n)
                ok = False

        # --- clean fixture => zero violations -------------------------------
        clean_root = os.path.join(tmp, "clean")
        build_fixture(clean_root, clean=True)
        ctx = make_ctx(repo_root=clean_root)
        vs = scan(ctx)
        if vs:
            print("SELFTEST FAIL: clean fixture produced violations: %s"
                  % json.dumps(vs, indent=2))
            ok = False

        # --- dirty fixture => the specific failures we claim to detect -------
        dirty_root = os.path.join(tmp, "dirty")
        build_fixture(dirty_root, clean=False)
        ctx2 = make_ctx(repo_root=dirty_root)
        vs2 = scan(ctx2)
        got = set(v["check"] for v in vs2)
        want = {"rationale-cap-fixed", "accepted-missing-dec", "probe-in-cell",
                "one-home-rule", "active-lessons-line-cap"}
        missing = want - got
        if missing:
            print("SELFTEST FAIL: dirty fixture missed %s (got %s)"
                  % (sorted(missing), sorted(got)))
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST %s: check_narrative.py" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="check_narrative.py",
        description="Ratchet narrative budget + naming doctrine validator.",
        epilog="exit 0 = clean/valid, 1 = violation/invalid, 2 = usage, "
               "3 = environment")
    ap.add_argument("--repo-root", help="repo root (default: derived)")
    ap.add_argument("--check", help="only report this check name")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--list", action="store_true", help="list check names")
    ap.add_argument("--validate-name", action="append", metavar="NAME",
                    help="validate a name per CONTRACT.md 6 (repeatable)")
    ap.add_argument("--names-file", metavar="FILE",
                    help="validate a newline-delimited list of names")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.list:
        for name, desc in CHECKS:
            print("%-24s %s" % (name, desc))
        return 0

    if args.selftest:
        return selftest()

    if args.validate_name or args.names_file:
        names = list(args.validate_name or [])
        if args.names_file:
            names.extend([l.strip() for l in
                          read_text(args.names_file).split("\n") if l.strip()])
        results = []
        bad = 0
        for n in names:
            valid, why = validate_name(n)
            if not valid:
                bad += 1
            results.append({"name": n, "valid": valid, "reason": why})
        if args.json:
            print(json.dumps({"names": results}, indent=2))
        else:
            for r in results:
                print("%s %s%s" % ("OK" if r["valid"] else "INVALID", r["name"],
                                   "" if r["valid"] else " " + r["reason"]))
        return 1 if bad else 0

    if args.check and args.check not in CHECK_NAMES:
        sys.stderr.write("unknown check %r; --list shows valid names\n" % args.check)
        return 2

    try:
        ctx = make_ctx(repo_root=args.repo_root)
        violations = scan(ctx, only=args.check)
    except EnvError as exc:
        sys.stderr.write("environment error: %s\n" % exc)
        return 3

    if args.json:
        print(json.dumps({"violations": violations,
                          "count": len(violations)}, indent=2))
    else:
        if not violations:
            print("narrative: clean (%d checks)"
                  % (1 if args.check else len(CHECKS)))
        for v in violations:
            print("%-24s %s :: %s" % (v["check"], v["site"], v["detail"]))
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
