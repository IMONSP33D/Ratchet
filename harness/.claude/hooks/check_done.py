#!/usr/bin/env python3
# =============================================================================
# check_done.py --- Ratchet definition-of-done checklist, run by stop-gate.sh at
# SHIP TIER (CONTRACT.md 5.2). Deterministic: every item here is a lookup, a
# count, or a string comparison. No judgement calls live in this file --- a
# checklist that can be talked out of a FAIL is not a checklist.
#
# STATES
#   PASS       required condition met
#   FAIL       required condition not met            -> exit 1
#   WARN       worth saying; never blocks             (e.g. ROLLOVER-REQUIRED)
#   SKIP       not applicable in this run/tier
#   DISCLOSED  a human read this exact failure text and ruled the run may ship
#              with it disclosed. Rendered DISCLOSED, NEVER PASS; excluded from
#              the exit code ONLY; reprinted in full every time.
#
# DISCLOSURE INTERFACE (owned by escalation-lib.sh; probed, never re-implemented):
#     . escalation-lib.sh
#     rt_esc_disclosed "<check-name>" "<sha256 of the failure text>"
#         exit 0 = disclosed, non-zero = not disclosed
#   The failure text hashed is EXACTLY the `detail` string this file prints for
#   the check, utf-8, no trailing newline. A different failure of the same check
#   hashes differently and therefore blocks --- which is the point.
#   If escalation-lib.sh is absent or does not implement it: NOTHING is
#   disclosed (fail closed --- a missing library never hides a red).
#
# NEVER-ESCALATABLE INTERFACE, same probing discipline:
#     rt_esc_never_escalatable "<rule-id>"   exit 0 = never escalatable
#     rt_esc_never_list                      one rule id per line   (fallback)
#
# Stdlib only. utf-8 on every open. No project nouns. Config values are READ
# from ratchet.config.sh --- no default is duplicated in Python.
#
# EXIT CODES
#   0  every required check PASSed (DISCLOSED / WARN / SKIP do not block)
#   1  at least one required check FAILed
#   2  usage error
#   3  environment error (config missing, not a repo) --- fail closed
#
# 2026-08-23: cut from 19 checks to 2 (decisions doc). The other 17 --
# win-rows, findings-ledger, rationale-caps, criticals, ship-report,
# decisions, ship-consent, checkpoints, context-current, narrative,
# escalations, lessons, metrics, recap, naming, retro-filed,
# consolidation-cadence -- audited the pipeline's own paperwork rather than a
# command's exit code. What survives are the two load-bearing checks: changed
# files subset of the manifest, and verify-last.json matching HEAD with exit
# 0. check_narrative.py and its former checks 5/12 delegation, proof_map.py's
# former check-3 delegation, and run_metrics.py's former check-15 delegation
# are gone with them.
# =============================================================================
"""Definition-of-done checklist for the Ratchet harness (ship tier)."""

import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile

PASS, FAIL, WARN, SKIP, DISCLOSED = "PASS", "FAIL", "WARN", "SKIP", "DISCLOSED"

CONFIG_KEYS = [
    "REPO_ROOT", "PIPELINE_DIR", "CONTEXT_DIR", "DEV_DIR", "CLAUDE_DIR",
    "HOOKS_DIR", "EVIDENCE_DIR", "SECRETS_DIR",
    "RUN_ACTIVE", "RUN_START", "READY_TO_SHIP", "PLAN_FILES", "AMENDMENTS",
    "FINDINGS", "VERIFY_LAST", "RED_BASELINE", "SHIP_CONSENT", "RECAP",
    "CHECKPOINTS_DIR", "ESCALATIONS_DIR", "EVENTS_LOG", "METRICS_JSON",
    "RUN_JOURNAL", "CONTEXT_LIVE", "ACTIVE_LESSONS", "PENDING_ACTIONS",
    "BASE_BRANCH", "AGENT_BRANCH_PREFIX",
    "CAP_RATIONALE_FIXED", "CAP_RATIONALE_ACCEPTED", "CAP_RECAP_WORDS",
    "DECISIONS_HOT_SOFT_LINES", "DECISIONS_HOT_HARD_LINES",
    "MAX_REVIEW_ROUNDS", "ESCALATION_LEDGER", "STACK_NAME", "FAILURE_LINE_REGEX",
]

# --- frozen artifact shapes (CONTRACT.md 7) --------------------------------
LEDGER_HEADER_CELLS = ["name", "source", "severity as filed", "file:line",
                       "finding", "disposition", "rationale", "DEC"]
DISPOSITIONS = ("FIXED", "ACCEPTED", "DEFERRED", "WAIVED")
RECAP_HEADINGS = ["What got done", "Where the project stands", "What's next",
                  "Issues you should know about", "How close to launch"]
AMENDMENT_RE = re.compile(r"^(\S+)\s+(DEC-\d{3,})(?:\s+(.*))?$")
DEC_RE = re.compile(r"DEC-\d{3,}")
VERDICT_RE = re.compile(r"^(CLEAR|BLOCK: .+|ESCALATE: .+)$")

# Invented by this file (not frozen in CONTRACT.md) --- see the report:
SHIP_REPORT_NAME = "ship-report.md"          # under PIPELINE_DIR
SHIP_REPORT_SECTIONS = ["What shipped", "WIN rows", "Checkpoint ledger",
                        "Findings and dispositions", "Deviations and acceptances"]
MANDATORY_CHECKPOINT_STAGES = ["research", "contracts", "security", "ship"]
BOARD_OUTPUTS = ["reviewer-findings.md", "security-findings.md"]  # CONTRACT 7.5
# Generated (not authored) artifacts that need no manifest row:
GENERATED_EVIDENCE = ("proof-map.md", "probes/")


class EnvError(Exception):
    """Fail closed --- exit 3."""


# ---------------------------------------------------------------------------
# Config (single source of truth is the shell config; nothing defaulted here)
# ---------------------------------------------------------------------------
_EXTRACT = (
    'set -u; cfg="$1"; shift; '
    '. "$cfg" >/dev/null 2>&1 || exit 9; '
    'for v in "$@"; do eval "val=\\${$v-}"; printf "%s\\t%s\\n" "$v" "$val"; done'
)


def find_hooks_dir():
    return os.path.dirname(os.path.abspath(__file__))


def find_repo_root(hooks_dir):
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and os.path.isdir(env):
        return os.path.abspath(env)
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


def load_config(cfg_path, root, keys):
    if not os.path.isfile(cfg_path):
        raise EnvError("ratchet.config.sh not found at %s (fail closed)" % cfg_path)
    if not shutil.which("bash"):
        raise EnvError("bash not on PATH; cannot read config (fail closed)")
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = root
    proc = subprocess.run(["bash", "-c", _EXTRACT, "bash", cfg_path] + list(keys),
                          capture_output=True, text=True, timeout=60, env=env)
    if proc.returncode == 9:
        raise EnvError("could not source %s: %s" % (cfg_path, proc.stderr.strip()))
    if proc.returncode != 0:
        raise EnvError("config extraction failed (%d)" % proc.returncode)
    out = {}
    for line in proc.stdout.replace("\r", "").split("\n"):
        if "\t" in line:
            k, v = line.split("\t", 1)
            out[k] = v
    return out


def utc_now_iso():
    """UTC timestamp, 3.8-safe and without datetime.utcnow()'s deprecation."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().replace("\r\n", "\n").replace("\r", "\n")
    except (IOError, OSError):
        return ""


def word_count(text):
    return len([t for t in re.split(r"\s+", (text or "").strip()) if t])


class Ctx(object):
    """Resolved run context + memoised artifact reads."""

    def __init__(self, hooks_dir, root, cfg_path, cfg, tier=None):
        self.hooks_dir = hooks_dir
        self.root = root
        self.cfg_path = cfg_path
        self.cfg = cfg
        self._esc_lib = None
        self.tier = tier or self.detect_tier()

    # -- config accessors --
    def path(self, key):
        v = self.cfg.get(key, "")
        if not v:
            return None
        return v if os.path.isabs(v) else os.path.join(self.root, v)

    def num(self, key):
        v = (self.cfg.get(key) or "").strip()
        try:
            return int(v)
        except ValueError:
            return None

    def rel(self, p):
        try:
            return os.path.relpath(p, self.root).replace(os.sep, "/")
        except ValueError:
            return p

    # -- run state --
    def run_active(self):
        p = self.path("RUN_ACTIVE")
        return bool(p and os.path.isfile(p))

    def milestone(self):
        p = self.path("RUN_ACTIVE")
        if p and os.path.isfile(p):
            raw = read_text(p).strip().split("\n")[0].strip()
            m = re.search(r"M\d+", raw)
            return m.group(0) if m else raw
        return ""

    def detect_tier(self):
        p = self.path("READY_TO_SHIP")
        return "ship" if (p and os.path.isfile(p)) else "intermediate"

    def sibling(self, name):
        return os.path.join(self.hooks_dir, name)

    def git(self, *args):
        try:
            out = subprocess.run(["git"] + list(args), cwd=self.root,
                                 capture_output=True, text=True, timeout=90)
            if out.returncode == 0:
                return out.stdout.replace("\r", "").strip()
        except Exception:
            pass
        return ""

    def head(self):
        return self.git("rev-parse", "HEAD")

    # -- escalation library probing (never re-implement the HMAC or rule sets) --
    def esc_lib(self):
        if self._esc_lib is None:
            hooks = self.path("HOOKS_DIR") or self.hooks_dir
            cand = os.path.join(hooks, "escalation-lib.sh")
            if not os.path.isfile(cand):
                cand = os.path.join(self.hooks_dir, "escalation-lib.sh")
            self._esc_lib = cand if os.path.isfile(cand) else ""
        return self._esc_lib

    def esc_call(self, func, *args):
        """Return (rc, stdout). rc 8 = function absent, 9 = lib unsourceable,
        10 = no library at all."""
        lib = self.esc_lib()
        if not lib:
            return 10, ""
        snippet = ('set -u; lib="$1"; fn="$2"; shift 2; '
                   '. "$lib" >/dev/null 2>&1 || exit 9; '
                   'command -v "$fn" >/dev/null 2>&1 || exit 8; "$fn" "$@"')
        try:
            proc = subprocess.run(["bash", "-c", snippet, "bash", lib, func] +
                                  [str(a) for a in args],
                                  cwd=self.root, capture_output=True, text=True,
                                  timeout=60, stdin=subprocess.DEVNULL,
                                  env=dict(os.environ, CLAUDE_PROJECT_DIR=self.root))
            return proc.returncode, proc.stdout.replace("\r", "").strip()
        except Exception:
            return 9, ""

    def disclosed(self, check_name, detail):
        sha = hashlib.sha256(detail.encode("utf-8")).hexdigest()
        rc, _ = self.esc_call("rt_esc_disclosed", check_name, sha)
        return rc == 0

    # narrative()/metrics() sibling-delegation methods (used by the removed
    # narrative/metrics checks) were removed with checks 3-19, 2026-08-23.


def make_ctx(repo_root=None, tier=None):
    hd = find_hooks_dir()
    root = repo_root or find_repo_root(hd)
    cfg_path = os.path.join(hd, "ratchet.config.sh")
    if repo_root:
        cand = os.path.join(repo_root, ".claude", "hooks", "ratchet.config.sh")
        if os.path.isfile(cand):
            cfg_path = cand
    cfg = load_config(cfg_path, root, CONFIG_KEYS)
    cfg_root = (cfg.get("REPO_ROOT") or "").strip()
    if repo_root is None and cfg_root and os.path.isdir(cfg_root):
        root = os.path.abspath(cfg_root)
    return Ctx(hd, root, cfg_path, cfg, tier=tier)


# ---------------------------------------------------------------------------
# Shared parsers
# ---------------------------------------------------------------------------
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


def parse_table(text, required_cols):
    """Return (header_lower, [(lineno, cells)]) for the first table carrying all
    required column names. Columns are matched BY NAME, never by position."""
    header = None
    rows = []
    for i, line in enumerate(text.split("\n"), start=1):
        cells = split_row(line)
        if cells is None:
            if header is not None and rows:
                break
            header = None
            continue
        low = [c.strip().lower() for c in cells]
        if header is None:
            if all(rc.lower() in low for rc in required_cols):
                header = low
            continue
        if is_separator_row(cells):
            continue
        rows.append((i, cells))
    return header, rows


def col(cells, header, name):
    key = name.strip().lower()
    if header is None or key not in header:
        return ""
    i = header.index(key)
    return cells[i].strip() if i < len(cells) else ""


def parse_ledger(ctx):
    """(header_cells, [(lineno, cells)]) for FINDINGS. header_cells is the raw
    header text so check 4 can compare it to the frozen wording."""
    p = ctx.path("FINDINGS")
    if not p or not os.path.isfile(p):
        return None, [], None
    text = read_text(p)
    header_raw = None
    rows = []
    for i, line in enumerate(text.split("\n"), start=1):
        cells = split_row(line)
        if cells is None:
            continue
        if header_raw is None:
            if cells and cells[0].strip().lower() in ("name", "id"):
                header_raw = cells
            continue
        if is_separator_row(cells):
            continue
        if len(cells) >= 2:
            rows.append((i, cells))
    return header_raw, rows, p


def ledger_cell(cells, header_raw, name):
    if not header_raw:
        return ""
    low = [c.strip().lower() for c in header_raw]
    key = name.strip().lower()
    if key not in low:
        return ""
    i = low.index(key)
    return cells[i].strip() if i < len(cells) else ""


def parse_amendments(ctx):
    """CONTRACT.md 7.6: `<path> <DEC-id> [note]`, one per line. This is the
    shared form the Stop gate parses too --- keep the regex identical."""
    p = ctx.path("AMENDMENTS")
    good, bad = [], []
    if not p or not os.path.isfile(p):
        return good, bad
    for i, line in enumerate(read_text(p).split("\n"), start=1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = AMENDMENT_RE.match(s)
        if m:
            good.append({"path": norm_path(m.group(1)), "dec": m.group(2),
                         "note": (m.group(3) or "").strip(), "line": i})
        else:
            bad.append((i, s))
    return good, bad


def norm_path(p):
    p = (p or "").strip().replace("\\", "/").replace("\r", "")
    while p.startswith("./"):
        p = p[2:]
    return p.strip("/") if p.startswith("/") else p


def plan_paths(ctx):
    p = ctx.path("PLAN_FILES")
    out = []
    if p and os.path.isfile(p):
        for line in read_text(p).split("\n"):
            s = norm_path(line)
            if s and not s.startswith("#"):
                out.append(s)
    return out


def changed_files(ctx):
    """Committed-on-branch + working-tree changes, repo-relative POSIX."""
    files = set()
    base = (ctx.cfg.get("BASE_BRANCH") or "").strip() or "main"
    mb = ctx.git("merge-base", base, "HEAD")
    degraded = False
    if mb:
        for line in ctx.git("diff", "--name-only", "%s..HEAD" % mb).split("\n"):
            if line.strip():
                files.add(norm_path(line))
    else:
        degraded = True
    for line in ctx.git("status", "--porcelain").split("\n"):
        if not line.strip():
            continue
        payload = line[3:] if len(line) > 3 else ""
        if " -> " in payload:
            payload = payload.split(" -> ", 1)[1]
        payload = payload.strip().strip('"')
        if payload:
            files.add(norm_path(payload))
    return files, degraded


def board_findings(ctx):
    """CONTRACT.md 7.5: one numbered finding per item, `1.` at line start."""
    pdir = ctx.path("PIPELINE_DIR")
    items, present = [], []
    if not pdir:
        return items, present
    for fn in BOARD_OUTPUTS:
        p = os.path.join(pdir, fn)
        if not os.path.isfile(p):
            continue
        present.append(fn)
        for i, line in enumerate(read_text(p).split("\n"), start=1):
            m = re.match(r"^\s{0,3}(\d+)\.\s+(.*)$", line)
            if m:
                body = m.group(2)
                nm = re.match(r"[`*]*([a-z][a-z0-9-]*)[`*]*", body)
                sev = ""
                ms = re.search(r"\b(CRITICAL|HIGH|MEDIUM|LOW)\b", body)
                if ms:
                    sev = ms.group(1)
                items.append({"file": fn, "line": i,
                              "name": nm.group(1) if nm else "",
                              "severity": sev, "text": body})
    return items, present


def decisions_entries(ctx):
    cdir = ctx.path("CONTEXT_DIR")
    if not cdir:
        return [], None
    p = os.path.join(cdir, "DECISIONS.md")
    if not os.path.isfile(p):
        return [], p
    text = read_text(p)
    lines = text.split("\n")
    entries, cur = [], None
    for i, line in enumerate(lines, start=1):
        m = re.match(r"^##\s+(DEC-\d{3,})\s*(?:[·\-—:]\s*(.*))?$", line)
        if m:
            if cur:
                entries.append(cur)
            cur = {"id": m.group(1), "name": (m.group(2) or "").strip(),
                   "line": i, "body": []}
        elif cur is not None:
            cur["body"].append(line)
    if cur:
        entries.append(cur)
    for e in entries:
        e["text"] = "\n".join(e["body"])
    return entries, p


# ---------------------------------------------------------------------------
# Result plumbing
# ---------------------------------------------------------------------------
class Result(object):
    def __init__(self, number, name, status, detail="", extra=None):
        self.number = number
        self.name = name
        self.status = status
        self.detail = detail
        self.extra = extra or []

    def to_dict(self):
        return {"number": self.number, "name": self.name, "status": self.status,
                "detail": self.detail, "extra": self.extra}


def ok(n, name, detail=""):
    return Result(n, name, PASS, detail)


def bad(n, name, detail, extra=None):
    return Result(n, name, FAIL, detail, extra)


def warn(n, name, detail):
    return Result(n, name, WARN, detail)


def skip(n, name, detail):
    return Result(n, name, SKIP, detail)


# ---------------------------------------------------------------------------
# 1  gate-artifact
# ---------------------------------------------------------------------------
def check_gate_artifact(ctx):
    n, name = 1, "gate-artifact"
    p = ctx.path("VERIFY_LAST")
    if not p:
        return bad(n, name, "VERIFY_LAST is unset in ratchet.config.sh")
    if not os.path.isfile(p):
        return bad(n, name, "VERIFY_LAST missing at %s: the deterministic gate "
                            "has not run at this tier" % ctx.rel(p))
    try:
        data = json.loads(read_text(p))
    except ValueError:
        return bad(n, name, "VERIFY_LAST is not valid JSON (%s)" % ctx.rel(p))
    missing = [k for k in ("tier", "head_sha", "exit") if k not in data]
    if missing:
        return bad(n, name, "VERIFY_LAST missing field(s): %s" % ", ".join(missing))
    head = ctx.head()
    problems = []
    if head and data.get("head_sha") != head:
        problems.append("recorded head_sha %s != HEAD %s (stale artifact; re-run "
                        "the gate)" % (str(data.get("head_sha"))[:12], head[:12]))
    if ctx.tier == "ship" and str(data.get("tier")) != "ship":
        problems.append("recorded tier %r but this is ship tier" % data.get("tier"))
    try:
        rc = int(data.get("exit"))
    except (TypeError, ValueError):
        rc = None
        problems.append("exit is not an integer: %r" % data.get("exit"))
    if rc is not None and rc != 0:
        tail = (data.get("tail") or "").strip().split("\n")
        problems.append("gate exited %d; tail: %s"
                        % (rc, " / ".join(tail[-3:]) if tail else "(empty)"))
    if problems:
        return bad(n, name, "; ".join(problems))
    return ok(n, name, "verify-last.json at HEAD %s, tier %s, exit 0"
              % (head[:12] or "?", data.get("tier")))


# ---------------------------------------------------------------------------
# 2  manifest-scope
# ---------------------------------------------------------------------------
def check_manifest_scope(ctx):
    n, name = 2, "manifest-scope"
    good, bad_lines = parse_amendments(ctx)
    if bad_lines:
        return bad(n, name,
                   "malformed amendment line(s) --- the shared form is "
                   "`<path> <DEC-id> [note]`: %s"
                   % "; ".join("%d:%s" % (i, s) for i, s in bad_lines[:5]))
    allowed = set(plan_paths(ctx)) | set(a["path"] for a in good)
    exempt_dirs = []
    for key in ("PIPELINE_DIR", "DEV_DIR"):
        v = (ctx.cfg.get(key) or "").strip()
        if v:
            exempt_dirs.append(norm_path(v) + "/")
    evidence = norm_path((ctx.cfg.get("EVIDENCE_DIR") or "").strip())
    changed, degraded = changed_files(ctx)
    extra = []
    for f in sorted(changed):
        if f in allowed:
            continue
        if any(f.startswith(d) for d in exempt_dirs):
            continue
        if evidence and f.startswith(evidence + "/") and \
                any(g in f for g in GENERATED_EVIDENCE):
            continue
        extra.append(f)
    if extra:
        return bad(n, name,
                   "%d changed file(s) outside the manifest and its amendments: %s"
                   % (len(extra), ", ".join(extra[:10])),
                   extra)
    detail = "%d changed file(s), all in plan-files (%d) or amendments (%d)" % (
        len(changed), len(plan_paths(ctx)), len(good))
    if degraded:
        return warn(n, name, detail + "; NOTE: no merge-base with %s, scope "
                                      "derived from the working tree only"
                    % (ctx.cfg.get("BASE_BRANCH") or "main"))
    return ok(n, name, detail)


# ---------------------------------------------------------------------------
# Checks 3-19 (win-rows, findings-ledger, rationale-caps, criticals,
# ship-report, decisions, ship-consent, checkpoints, context-current,
# narrative, escalations, lessons, metrics, recap, naming, retro-filed,
# consolidation-cadence) were removed 2026-08-23 per the decisions doc: only
# the two load-bearing checks survive -- changed files subset of the manifest,
# and verify-last.json matching HEAD with exit 0. The other 17 audited the
# pipeline's own paperwork rather than a command's exit code. check_done.py
# stays: a Stop hook with nothing to consult is just "the model says it's
# finished," and these two checks are that consultation.



# ---------------------------------------------------------------------------
# Registry / runner
# ---------------------------------------------------------------------------
CHECKS = [
    (1, "gate-artifact", "VERIFY_LAST exists, matches HEAD and tier, exit 0",
     check_gate_artifact),
    (2, "manifest-scope", "changed files subset of plan-files + amendments",
     check_manifest_scope),
]
CHECK_NAMES = [c[1] for c in CHECKS]


def run_checks(ctx, only=None):
    results = []
    for number, name, _desc, fn in CHECKS:
        if only and name != only:
            continue
        try:
            r = fn(ctx)
        except EnvError:
            raise
        except Exception as exc:                      # a crashing check is a FAIL
            r = Result(number, name, FAIL,
                       "checker raised %s: %s (fail closed)"
                       % (type(exc).__name__, exc))
        if r.status == FAIL and ctx.disclosed(r.name, r.detail):
            r.status = DISCLOSED
        results.append(r)
    return results


def render(results, ctx, as_json=False):
    if as_json:
        return json.dumps({
            "tier": ctx.tier,
            "milestone": ctx.milestone(),
            "head_sha": ctx.head(),
            "generated_at": utc_now_iso(),
            "results": [r.to_dict() for r in results],
            "failed": [r.name for r in results if r.status == FAIL],
            "disclosed": [r.name for r in results if r.status == DISCLOSED],
        }, indent=2)
    out = []
    out.append("definition of done --- tier=%s milestone=%s head=%s"
               % (ctx.tier, ctx.milestone() or "-", (ctx.head() or "?")[:12]))
    for r in results:
        out.append("%2d %-16s %-9s %s" % (r.number, r.name, r.status, r.detail))
    dis = [r for r in results if r.status == DISCLOSED]
    if dis:
        out.append("")
        out.append("DISCLOSED reds --- reprinted in full at every block. A "
                   "disclosure never means the check passes; it means a human read "
                   "this exact failure and ruled the run may ship with it disclosed:")
        for r in dis:
            out.append("  [%s] %s" % (r.name, r.detail))
    fails = [r for r in results if r.status == FAIL]
    out.append("")
    out.append("%d PASS / %d FAIL / %d WARN / %d DISCLOSED / %d SKIP"
               % (len([r for r in results if r.status == PASS]), len(fails),
                  len([r for r in results if r.status == WARN]), len(dis),
                  len([r for r in results if r.status == SKIP])))
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Selftest --- for EVERY check, a realistic input that makes it FAIL.
# ---------------------------------------------------------------------------
FIXTURE_CONFIG = """#!/usr/bin/env bash
# Selftest fixture config.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
PIPELINE_DIR=".pipeline"
CONTEXT_DIR=".context"
DEV_DIR=".agent-development"
CLAUDE_DIR=".claude"
HOOKS_DIR=".claude/hooks"
EVIDENCE_DIR="docs/evidence"
SECRETS_DIR="secrets"
RUN_ACTIVE=".pipeline/run-active"
RUN_START=".pipeline/run-start"
READY_TO_SHIP=".pipeline/ready-to-ship"
PLAN_FILES=".pipeline/plan-files.txt"
AMENDMENTS=".pipeline/manifest-amendments.txt"
FINDINGS=".pipeline/findings.md"
VERIFY_LAST=".pipeline/verify-last.json"
RED_BASELINE=".pipeline/red-baseline.txt"
SHIP_CONSENT=".pipeline/ship-consent.json"
RECAP=".pipeline/recap.md"
CHECKPOINTS_DIR=".pipeline/checkpoints"
ESCALATIONS_DIR=".pipeline/escalations"
ESCALATION_LEDGER=".pipeline/escalations/ledger.jsonl"
EVENTS_LOG=".pipeline/run-events.jsonl"
METRICS_JSON=".pipeline/run-metrics.json"
RUN_JOURNAL=".pipeline/run-journal.md"
CONTEXT_LIVE=".pipeline/context-live.md"
ACTIVE_LESSONS=".agent-development/ACTIVE-LESSONS.md"
PENDING_ACTIONS=".agent-development/PENDING-HUMAN-ACTIONS.md"
BASE_BRANCH="main"
AGENT_BRANCH_PREFIX="agent/"
CAP_RATIONALE_FIXED=40
CAP_RATIONALE_ACCEPTED=80
CAP_CHECKPOINT_SUMMARY=500
CAP_CLEAR_VERDICT=200
CAP_RECAP_WORDS=400
CAP_RETRO_LINES=220
CAP_ACTIVE_LESSONS_LINES=100
DECISIONS_HOT_SOFT_LINES=250
DECISIONS_HOT_HARD_LINES=300
MAX_REVIEW_ROUNDS=2
STACK_NAME="fixture"
FAILURE_LINE_REGEX="^FAILED "
COLLECT_TESTS_CMD='printf "tests/test_gate.py::test_head_match\\n"'
"""

# Stub escalation library: documents the interface check_done probes for.
FIXTURE_ESC_LIB = """#!/usr/bin/env bash
# Selftest stub for escalation-lib.sh --- the two functions check_done probes.
rt_esc_never_list() {
  printf '%s\\n' secrets force-push base-branch-write control-layer
}
rt_esc_never_escalatable() {
  rt_esc_never_list | grep -qx -- "$1"
}
rt_esc_disclosed() {
  f="${REPO_ROOT:-$PWD}/.pipeline/escalations/disclosures"
  [ -f "$f" ] || return 1
  grep -qx -- "$1 $2" "$f"
}
"""


def _w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def _git(root, *args):
    subprocess.run(["git"] + list(args), cwd=root, capture_output=True, text=True,
                   timeout=90)


def build_good(root):
    """A repo that satisfies every check. Each mutator below breaks exactly one."""
    hooks = os.path.join(root, ".claude", "hooks")
    _w(os.path.join(hooks, "ratchet.config.sh"), FIXTURE_CONFIG)
    _w(os.path.join(hooks, "escalation-lib.sh"), FIXTURE_ESC_LIB)
    _w(os.path.join(root, "src", "widget.py"), "VALUE = 1\n")
    _w(os.path.join(root, "tests", "test_gate.py"),
       "def test_head_match():\n    assert True\n")
    _w(os.path.join(root, ".context", "MILESTONES.md"),
       "# Milestones\n\n"
       "| win | name | requirements | verify | evidence |\n"
       "|---|---|---|---|---|\n"
       "| WIN-M1-01 | gate-artifact-matches-head | REQ-1 | `make verify` "
       "| docs/evidence/M1/win-01.txt |\n")
    _w(os.path.join(root, ".context", "DECISIONS.md"),
       "# Decisions\n\n"
       "## DEC-004 · scope-widened-for-proof-map\n"
       "**Date.** 2026-08-20 · **Status.** ACTIVE\n"
       "**Decision.** The proof map is generated, not authored.\n"
       "**Affected.** REQ-1\n"
       "**Simulated.** Simulated against 3 frozen rows; none changed.\n"
       "**Archive.** .context/archive/decisions/DEC-004-full.md\n")
    _w(os.path.join(root, "docs", "evidence", "M1", "win-01.txt"), "raw output\n")
    _w(os.path.join(root, ".pipeline", "contracts.md"),
       "| win | name | selector |\n|---|---|---|\n"
       "| WIN-M1-01 | gate-artifact-matches-head | tests/test_gate.py |\n")
    _w(os.path.join(root, ".pipeline", "run-active"), "M1\n")
    _w(os.path.join(root, ".pipeline", "ready-to-ship"), "M1\n")
    _w(os.path.join(root, ".pipeline", "plan-files.txt"),
       "src/widget.py\ntests/test_gate.py\n.context/MILESTONES.md\n"
       ".context/DECISIONS.md\ndocs/evidence/M1/win-01.txt\n"
       ".claude/hooks/ratchet.config.sh\n.claude/hooks/escalation-lib.sh\n")
    _w(os.path.join(root, ".pipeline", "manifest-amendments.txt"),
       "docs/evidence/M1/win-01.txt DEC-004 evidence capture\n")
    _w(os.path.join(root, ".pipeline", "findings.md"),
       "| name | source | severity as filed | file:line | finding | disposition | "
       "rationale | DEC |\n|---|---|---|---|---|---|---|---|\n"
       "| gate-blames-wrong-actor | reviewer | HIGH | src/widget.py:1 | wrong actor "
       "blamed | FIXED | corrected in the gate | DEC-004 |\n"
       "| ledger-count-drifts | security | MEDIUM | src/widget.py:1 | count drifts "
       "| ACCEPTED | measured cost exceeds the benefit this milestone | DEC-004 |\n")
    _w(os.path.join(root, ".pipeline", "reviewer-findings.md"),
       "1. gate-blames-wrong-actor HIGH --- wrong actor blamed\n")
    _w(os.path.join(root, ".pipeline", "security-findings.md"),
       "1. ledger-count-drifts MEDIUM --- count drifts\n")
    _w(os.path.join(root, ".pipeline", "ship-report.md"),
       "# Ship report\n\n## What shipped\nx\n\n## WIN rows\nx\n\n"
       "## Checkpoint ledger\nx\n\n## Findings and dispositions\nx\n\n"
       "## Deviations and acceptances\nx\n")
    _w(os.path.join(root, ".pipeline", "recap.md"),
       "## What got done\nA gate.\n\n## Where the project stands\nGreen.\n\n"
       "## What's next\nM2.\n\n## Issues you should know about\nNone.\n\n"
       "## How close to launch\nClose.\n")
    _w(os.path.join(root, ".pipeline", "context-live.md"), "# Live\nM1 in flight.\n")
    _w(os.path.join(root, ".pipeline", "run-journal.md"), "# Journal\nM1 started.\n")
    for stage in MANDATORY_CHECKPOINT_STAGES:
        base = os.path.join(root, ".pipeline", "checkpoints", "1-%s" % stage)
        _w(base + "-jump.md", "# %s\nsummary\n" % stage)
        _w(base + "-evidence.txt", "git diff --stat\n")
        _w(base + "-clear.md", "Spot-checked the diff stat against the summary.\n"
                               "CLEAR\n")
    # Real shipped shape: a `## MUST-FIX` category heading groups `### <name>`
    # lesson headings, each with a backtick-wrapped `` `assert: <id>` `` line ---
    # see ACTIVE-LESSONS.md. This fixture must track that format exactly, or
    # this selftest is reader-writer-drift against its own production payload.
    _w(os.path.join(root, ".agent-development", "ACTIVE-LESSONS.md"),
       "# Active lessons\n\n## MUST-FIX --- the process has failed these ways\n\n"
       "### dispatch-glob-missing-degrades-gate\n"
       "The dispatch glob must degrade the gate when it is missing.\n"
       "`assert: tests/test_gate.py::test_head_match`\n")
    _w(os.path.join(root, ".agent-development", "PENDING-HUMAN-ACTIONS.md"),
       "# Pending\n\n## rotate-escalation-key\nOwner: human\n")
    # check 18/19 fixtures: this run's retro doc (CONTRACT 7.10) with a
    # matching INDEX.md row --- one run doc is not a multiple of 5, so check
    # 19 is satisfied by omission (no consolidation is due yet).
    _w(os.path.join(root, ".agent-development", "runs", "001-M1-shipped.md"),
       "# Retro 001 --- M1 --- shipped\n\nFixture retro.\n")
    _w(os.path.join(root, ".agent-development", "INDEX.md"),
       "# INDEX.md\n\n| run | milestone | outcome | date | PR | one-line result |\n"
       "|---|---|---|---|---|---|\n"
       "| 001 | M1 | `shipped` | 2026-08-20 | #42 | Fixture run shipped clean. |\n")
    _w(os.path.join(root, ".pipeline", "escalations", "ledger.jsonl"),
       json.dumps({"id": "esc-1", "rule": "delete-scope", "state": "consumed",
                   "postcondition": "", "postcondition_status": "n/a"}) + "\n")
    _w(os.path.join(root, ".pipeline", "run-events.jsonl"), "")
    # git history: base commit on main, work commit on the agent branch
    _git(root, "init", "-b", "main")
    _git(root, "config", "user.email", "selftest@example.invalid")
    _git(root, "config", "user.name", "ratchet-selftest")
    _w(os.path.join(root, "README.md"), "# fixture\n")
    _git(root, "add", "README.md")
    _git(root, "commit", "-m", "base")
    _git(root, "checkout", "-b", "agent/m1")
    _git(root, "add", "src", "tests", ".context", "docs", ".claude")
    _git(root, "commit", "-m", "work")
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root,
                          capture_output=True, text=True).stdout.strip()
    _w(os.path.join(root, ".pipeline", "verify-last.json"),
       json.dumps({"tier": "ship", "head_sha": head, "dirty_hash": "d0",
                   "exit": 0, "tail": "5 passed", "timestamp": 1700000000}))
    _w(os.path.join(root, "docs", "evidence", "M1", "proof-map.md"),
       "# Proof map --- M1\n\n"
       "<!-- ratchet:proof-map version=1 milestone=M1 head_sha=%s stack=fixture "
       "status=OK rows=1 zero=0 generated_at=2026-08-20T00:00:00Z -->\n\n"
       "| win | name | selector | tests | status |\n|---|---|---|---|---|\n"
       "| WIN-M1-01 | gate-artifact-matches-head | `tests/test_gate.py` | 1 | OK |\n"
       % head)
    _w(os.path.join(root, ".pipeline", "run-start"),
       "%d\n" % int(datetime.datetime.now().timestamp() - 60))
    # a consent record that matches HEAD --- check 9's PASS path (the mutator
    # below replaces it with one recorded for a different commit)
    _w(os.path.join(root, ".pipeline", "ship-consent.json"),
       json.dumps({"pr": 42, "head_sha": head, "base": "main",
                   "question": "Merge agent/m1 into main? (PR #42)",
                   "options_offered": ["Yes --- merge (Recommended)",
                                       "No --- hold the PR open",
                                       "Escalate to the arbiter"],
                   "answer": "Yes --- merge (Recommended)",
                   "answered_at": "2026-08-20T00:00:00Z"}))
    return head


# --- one mutator per check: the realistic input that makes it FAIL ---------
def _mut_gate_artifact(root):
    p = os.path.join(root, ".pipeline", "verify-last.json")
    d = json.loads(read_text(p))
    d["head_sha"] = "0" * 40           # gate artifact from an earlier commit
    _w(p, json.dumps(d))


def _mut_manifest_scope(root):
    _w(os.path.join(root, "src", "rogue.py"), "SNEAKED = True\n")


MUTATORS = {
    "gate-artifact": _mut_gate_artifact,
    "manifest-scope": _mut_manifest_scope,
}


def selftest(verbose=False):
    ok_all = True
    if not shutil.which("git"):
        print("SELFTEST FAIL: git is required for the scope/gate fixtures")
        return 1
    tmp = tempfile.mkdtemp(prefix="ratchet-checkdone-")
    try:
        # --- 1. the good fixture must be entirely clean --------------------
        good = os.path.join(tmp, "good")
        build_good(good)
        ctx = make_ctx(repo_root=good, tier="ship")
        results = run_checks(ctx)
        fails = [r for r in results if r.status == FAIL]
        if fails:
            ok_all = False
            print("SELFTEST FAIL: good fixture produced FAILs:")
            for r in fails:
                print("   %d %s: %s" % (r.number, r.name, r.detail))
        elif verbose:
            print(render(results, ctx))

        # --- 2. every check must FAIL on a realistic broken input ----------
        for number, name, _desc, _fn in CHECKS:
            mut = MUTATORS.get(name)
            if mut is None:
                print("SELFTEST FAIL: check %r has no failure input" % name)
                ok_all = False
                continue
            root = os.path.join(tmp, "bad-%s" % name)
            build_good(root)
            mut(root)
            c = make_ctx(repo_root=root, tier="ship")
            res = run_checks(c, only=name)
            if not res or res[0].status != FAIL:
                ok_all = False
                print("SELFTEST FAIL: check %r did not FAIL on its broken input "
                      "(got %s: %s)" % (name, res[0].status if res else "nothing",
                                        res[0].detail if res else ""))
            elif verbose:
                print("  %-16s FAIL as expected: %s" % (name, res[0].detail[:100]))

        # --- 3. a disclosure renders DISCLOSED, never PASS, and clears exit -
        root = os.path.join(tmp, "disclosed")
        build_good(root)
        _mut_gate_artifact(root)
        c = make_ctx(repo_root=root, tier="ship")
        red = run_checks(c, only="gate-artifact")[0]
        sha = hashlib.sha256(red.detail.encode("utf-8")).hexdigest()
        _w(os.path.join(root, ".pipeline", "escalations", "disclosures"),
           "gate-artifact %s\n" % sha)
        c2 = make_ctx(repo_root=root, tier="ship")
        res = run_checks(c2)
        got = [r for r in res if r.name == "gate-artifact"][0]
        if got.status != DISCLOSED:
            ok_all = False
            print("SELFTEST FAIL: disclosed failure should render DISCLOSED, got %s"
                  % got.status)
        if any(r.status == FAIL for r in res):
            ok_all = False
            print("SELFTEST FAIL: a disclosed red must be excluded from the exit "
                  "code")
        # a DIFFERENT failure of the same check must still block
        p = os.path.join(root, ".pipeline", "verify-last.json")
        d = json.loads(read_text(p))
        d["exit"] = 1
        d["tail"] = "FAILED tests/test_gate.py::test_head_match"
        _w(p, json.dumps(d))
        c3 = make_ctx(repo_root=root, tier="ship")
        got2 = run_checks(c3, only="gate-artifact")[0]
        if got2.status != FAIL:
            ok_all = False
            print("SELFTEST FAIL: a disclosure must bind to the failure TEXT; a "
                  "different failure of the same check must block (got %s)"
                  % got2.status)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST %s: check_done.py (%d checks, %d failure inputs)"
          % ("PASS" if ok_all else "FAIL", len(CHECKS), len(MUTATORS)))
    return 0 if ok_all else 1


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="check_done.py",
        description="Ratchet definition-of-done checklist (ship tier). Every item "
                    "is a lookup, a count, or a string comparison.",
        epilog="exit 0 = every required check passed (DISCLOSED/WARN/SKIP do not "
               "block), 1 = a required check FAILed, 2 = usage, 3 = environment")
    ap.add_argument("--check", metavar="NAME", help="run only this check")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--list", action="store_true", help="list checks and exit")
    ap.add_argument("--tier", choices=["ship", "intermediate"],
                    help="override tier detection (default: READY_TO_SHIP presence)")
    ap.add_argument("--repo-root")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    if args.list:
        for number, name, desc, _fn in CHECKS:
            print("%2d  %-16s %s" % (number, name, desc))
        return 0
    if args.selftest:
        return selftest(verbose=args.verbose)
    if args.check and args.check not in CHECK_NAMES:
        sys.stderr.write("unknown check %r; --list shows valid names\n" % args.check)
        return 2

    try:
        ctx = make_ctx(repo_root=args.repo_root, tier=args.tier)
    except EnvError as exc:
        sys.stderr.write("environment error: %s\n" % exc)
        return 3
    if not ctx.run_active():
        # CONTRACT.md 5.1: with no run active there is no definition of done.
        if args.json:
            print(json.dumps({"tier": "inert", "results": [], "failed": [],
                              "disclosed": [],
                              "note": "no run active; definition-of-done is inert"},
                             indent=2))
        else:
            print("no run active (RUN_ACTIVE absent): definition-of-done is inert")
        return 0
    try:
        results = run_checks(ctx, only=args.check)
    except EnvError as exc:
        sys.stderr.write("environment error: %s\n" % exc)
        return 3
    print(render(results, ctx, as_json=args.json))
    return 1 if any(r.status == FAIL for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
