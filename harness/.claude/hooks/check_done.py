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
# NEVER-ESCALATABLE INTERFACE (check 13), same probing discipline:
#     rt_esc_never_escalatable "<rule-id>"   exit 0 = never escalatable
#     rt_esc_never_list                      one rule id per line   (fallback)
#
# SIBLING DELEGATION (one home per question):
#   check_narrative.py  -> checks 5 and 12   (word/line caps, one-home rule)
#   proof_map.py --verify -> check 3          (WIN rows collect >= 1 test)
#   run_metrics.py --json -> check 15         (cross-counter contradictions)
#
# Stdlib only. utf-8 on every open. No project nouns. Config values are READ
# from ratchet.config.sh --- no default is duplicated in Python.
#
# EXIT CODES
#   0  every required check PASSed (DISCLOSED / WARN / SKIP do not block)
#   1  at least one required check FAILed
#   2  usage error
#   3  environment error (config missing, not a repo) --- fail closed
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
        self._narrative = None
        self._metrics = None
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

    # -- memoised sibling results --
    def narrative(self):
        if self._narrative is None:
            script = self.sibling("check_narrative.py")
            if not os.path.isfile(script):
                self._narrative = {"error": "check_narrative.py missing at %s"
                                            % script, "violations": []}
                return self._narrative
            proc = subprocess.run(
                [sys.executable, script, "--repo-root", self.root, "--json"],
                capture_output=True, text=True, timeout=300,
                env=dict(os.environ, CLAUDE_PROJECT_DIR=self.root))
            if proc.returncode == 3:
                self._narrative = {"error": proc.stderr.strip(), "violations": []}
            else:
                try:
                    self._narrative = json.loads(proc.stdout or "{}")
                    self._narrative.setdefault("violations", [])
                except ValueError:
                    self._narrative = {"error": "unparseable check_narrative output",
                                       "violations": []}
        return self._narrative

    def metrics(self):
        if self._metrics is None:
            script = self.sibling("run_metrics.py")
            if not os.path.isfile(script):
                self._metrics = {"error": "run_metrics.py missing"}
                return self._metrics
            proc = subprocess.run(
                [sys.executable, script, "--repo-root", self.root, "--json",
                 "--no-write", "--measure-end-state"],
                capture_output=True, text=True, timeout=300,
                env=dict(os.environ, CLAUDE_PROJECT_DIR=self.root))
            if proc.returncode == 3:
                self._metrics = {"error": proc.stderr.strip()}
            else:
                try:
                    self._metrics = json.loads(proc.stdout or "{}")
                except ValueError:
                    self._metrics = {"error": "unparseable run_metrics output"}
        return self._metrics


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
# 3  win-rows
# ---------------------------------------------------------------------------
def milestones_rows(ctx, milestone):
    """CONTRACT.md 7.1 WIN rows. Header-driven when a header exists, else the
    frozen positional order: win | name | requirements | verify | evidence."""
    cdir = ctx.path("CONTEXT_DIR")
    if not cdir:
        return [], None
    p = os.path.join(cdir, "MILESTONES.md")
    if not os.path.isfile(p):
        return [], p
    text = read_text(p)
    header, _rows = parse_table(text, ["win"])
    out = []
    for i, line in enumerate(text.split("\n"), start=1):
        cells = split_row(line)
        if not cells or is_separator_row(cells):
            continue
        if not re.match(r"^WIN-%s-\d+" % re.escape(milestone), cells[0].strip()):
            continue
        if header and "verify" in " ".join(header):
            vk = [h for h in header if "verify" in h][0]
            ek = ([h for h in header if "evidence" in h] or [""])[0]
            nk = ([h for h in header if h == "name"] or [""])[0]
            row = {"win": cells[0].strip(),
                   "name": col(cells, header, nk) if nk else "",
                   "verify": col(cells, header, vk),
                   "evidence": col(cells, header, ek) if ek else ""}
        else:
            row = {"win": cells[0].strip(),
                   "name": cells[1].strip() if len(cells) > 1 else "",
                   "verify": cells[3].strip() if len(cells) > 3 else "",
                   "evidence": cells[4].strip() if len(cells) > 4 else ""}
        row["line"] = i
        out.append(row)
    return out, p


UNWRITTEN_MARKER = "<!-- ratchet:unwritten -->"


def milestones_unwritten(ctx):
    """True when MILESTONES.md is still the shipped placeholder. The marker is
    machine-detectable on purpose: an unwritten milestone must FAIL loudly, not
    pass vacuously because a file with no WIN rows also has no bad WIN rows."""
    cdir = ctx.path("CONTEXT_DIR")
    if not cdir:
        return False
    p = os.path.join(cdir, "MILESTONES.md")
    if not os.path.isfile(p):
        return False
    return UNWRITTEN_MARKER in read_text(p)


def check_win_rows(ctx):
    n, name = 3, "win-rows"
    milestone = ctx.milestone()
    if not milestone:
        return skip(n, name, "no active run (RUN_ACTIVE empty): nothing to prove")
    if milestones_unwritten(ctx):
        msg = ("MILESTONES.md has not been written yet --- read .context/TEMPLATE.md "
               "and write it; a run cannot be judged against a milestone that does "
               "not exist")
        return bad(n, name, msg, [msg])
    rows, mpath = milestones_rows(ctx, milestone)
    problems = []
    if not rows:
        problems.append("no WIN rows for %s in %s" % (milestone, ctx.rel(mpath or "")))
    for r in rows:
        v = r["verify"].strip().strip("`")
        if not v or v in ("-", "n/a", "TBD"):
            problems.append("%s has no verify command --- a WIN row that cannot be "
                            "evaluated is a SETUP DEFECT; raise it, never adjudicate "
                            "it" % r["win"])
        ev = norm_path(r["evidence"].strip().strip("`"))
        if not ev or ev in ("-", "n/a"):
            problems.append("%s names no evidence path" % r["win"])
        elif not os.path.exists(os.path.join(ctx.root, ev)):
            problems.append("%s: evidence missing on disk (%s)" % (r["win"], ev))
    # proof map: delegated to its own writer/reader
    script = ctx.sibling("proof_map.py")
    if not os.path.isfile(script):
        problems.append("proof_map.py missing; proof map cannot be verified")
    else:
        proc = subprocess.run(
            [sys.executable, script, "--repo-root", ctx.root, "--verify",
             "--milestone", milestone, "--json"],
            capture_output=True, text=True, timeout=300,
            env=dict(os.environ, CLAUDE_PROJECT_DIR=ctx.root))
        try:
            v = json.loads(proc.stdout or "{}")
        except ValueError:
            v = {}
        if proc.returncode == 3:
            problems.append("proof map could not be verified: %s"
                            % (proc.stderr.strip() or "environment error"))
        elif not v.get("ok", False):
            for prob in (v.get("problems") or ["proof map missing or stale"]):
                problems.append("proof map: %s" % prob)
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    return ok(n, name, "%d WIN row(s) for %s: verify commands present, evidence on "
                       "disk, proof map at HEAD with >=1 test per row"
              % (len(rows), milestone))


# ---------------------------------------------------------------------------
# 4  findings-ledger
# ---------------------------------------------------------------------------
def check_findings_ledger(ctx):
    n, name = 4, "findings-ledger"
    header, rows, p = parse_ledger(ctx)
    if p is None:
        return bad(n, name, "findings ledger missing (%s): the board's output has "
                            "no home" % (ctx.cfg.get("FINDINGS") or "FINDINGS unset"))
    if header is None:
        return bad(n, name, "findings ledger has no parseable header row in %s"
                   % ctx.rel(p))
    got = [c.strip().lower() for c in header]
    want = [c.lower() for c in LEDGER_HEADER_CELLS]
    if got != want:
        return bad(n, name, "ledger header is %s but CONTRACT.md 7.4 freezes %s"
                   % ("| " + " | ".join(header) + " |",
                      "| " + " | ".join(LEDGER_HEADER_CELLS) + " |"))
    problems = []
    for lineno, cells in rows:
        sev = ledger_cell(cells, header, "severity as filed")
        disp = ledger_cell(cells, header, "disposition").upper()
        nm = ledger_cell(cells, header, "name")
        if not sev:
            problems.append("row %d (%s) has an empty severity-as-filed cell; that "
                            "column is the number of record and is never edited"
                            % (lineno, nm or "?"))
        if disp and disp not in DISPOSITIONS:
            problems.append("row %d (%s) disposition %r is not one of %s"
                            % (lineno, nm or "?", disp, "/".join(DISPOSITIONS)))
        if not disp:
            problems.append("row %d (%s) is unadjudicated (empty disposition)"
                            % (lineno, nm or "?"))
    items, present = board_findings(ctx)
    if not present:
        if problems:
            return bad(n, name, "; ".join(problems), problems)
        return warn(n, name, "ledger parses with %d row(s), but neither board raw "
                             "output is on disk (%s) --- row count unverifiable"
                    % (len(rows), ", ".join(BOARD_OUTPUTS)))
    if len(rows) != len(items):
        problems.append("ledger has %d row(s) but the board raw outputs (%s) filed "
                        "%d finding(s) --- every filed finding is recorded before "
                        "adjudication"
                        % (len(rows), ", ".join(present), len(items)))
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    return ok(n, name, "header frozen-exact; %d row(s) == %d finding(s) filed across "
                       "%s" % (len(rows), len(items), ", ".join(present)))


# ---------------------------------------------------------------------------
# 5  rationale-caps  (word counting delegated to check_narrative.py)
# ---------------------------------------------------------------------------
RATIONALE_CHECKS = ("rationale-cap-fixed", "rationale-cap-accepted",
                    "accepted-missing-dec")


def check_rationale_caps(ctx):
    n, name = 5, "rationale-caps"
    nar = ctx.narrative()
    if nar.get("error"):
        return bad(n, name, "check_narrative.py could not run: %s" % nar["error"])
    hits = [v for v in nar["violations"] if v["check"] in RATIONALE_CHECKS]
    if hits:
        return bad(n, name,
                   "%d rationale violation(s): %s" % (
                       len(hits),
                       "; ".join("%s %s (%s)" % (v["check"], v["site"], v["detail"])
                                 for v in hits[:6])),
                   [v["detail"] for v in hits])
    return ok(n, name, "FIXED <= %s words; ACCEPTED/DEFERRED/WAIVED <= %s words with "
                       "a DEC id" % (ctx.cfg.get("CAP_RATIONALE_FIXED"),
                                     ctx.cfg.get("CAP_RATIONALE_ACCEPTED")))


# ---------------------------------------------------------------------------
# 6  criticals
# ---------------------------------------------------------------------------
def check_criticals(ctx):
    n, name = 6, "criticals"
    header, rows, p = parse_ledger(ctx)
    problems = []
    ledger_names = set()
    if header:
        for lineno, cells in rows:
            nm = ledger_cell(cells, header, "name")
            ledger_names.add(nm)
            sev = ledger_cell(cells, header, "severity as filed").upper()
            disp = ledger_cell(cells, header, "disposition").upper()
            if "CRITICAL" in sev and disp != "FIXED":
                problems.append("%s is CRITICAL as filed with disposition %s --- a "
                                "CRITICAL cannot be accepted; fix it or raise a "
                                "Decision Card" % (nm or "row %d" % lineno,
                                                   disp or "(none)"))
    items, present = board_findings(ctx)
    for it in items:
        if it["severity"] == "CRITICAL" and it["name"] and \
                it["name"] not in ledger_names:
            problems.append("%s:%d files CRITICAL %s but it has no ledger row"
                            % (it["file"], it["line"], it["name"]))
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    return ok(n, name, "zero unresolved CRITICAL findings")


# ---------------------------------------------------------------------------
# 7  ship-report
# ---------------------------------------------------------------------------
def check_ship_report(ctx):
    n, name = 7, "ship-report"
    pdir = ctx.path("PIPELINE_DIR")
    if not pdir:
        return bad(n, name, "PIPELINE_DIR unset")
    p = os.path.join(pdir, SHIP_REPORT_NAME)
    if ctx.tier != "ship":
        if not os.path.isfile(p):
            return skip(n, name, "intermediate tier: no ship report expected yet")
    if not os.path.isfile(p):
        return bad(n, name, "ship report missing at %s --- it is the PR body and "
                            "the run's account of itself" % ctx.rel(p))
    text = read_text(p)
    have = [re.sub(r"^#+\s*", "", l).strip().rstrip(".")
            for l in text.split("\n") if l.strip().startswith("#")]
    have_low = [h.lower() for h in have]
    missing = [s for s in SHIP_REPORT_SECTIONS if s.lower() not in have_low]
    if missing:
        return bad(n, name, "ship report is missing required section(s): %s"
                   % ", ".join(missing))
    return ok(n, name, "all %d required sections present" % len(SHIP_REPORT_SECTIONS))


# ---------------------------------------------------------------------------
# 8  decisions
# ---------------------------------------------------------------------------
REQUIRED_DEC_FIELDS = ["Date.", "Status.", "Decision.", "Affected.", "Simulated."]
SIMULATED_RE = re.compile(
    r"Simulated against \d+(?: frozen rows)?;\s*(?:\d+ changed meaning:|none changed)",
    re.I)


def cited_dec_ids(ctx):
    cites = {}

    def add(where, text):
        for d in set(DEC_RE.findall(text or "")):
            cites.setdefault(d, set()).add(where)

    good, _bad = parse_amendments(ctx)
    for a in good:
        cites.setdefault(a["dec"], set()).add("amendments:%d" % a["line"])
    header, rows, fp = parse_ledger(ctx)
    if header:
        for lineno, cells in rows:
            add("findings:%d" % lineno, ledger_cell(cells, header, "DEC"))
    for key in ("ACTIVE_LESSONS", "PENDING_ACTIONS", "CONTEXT_LIVE", "RUN_JOURNAL"):
        p = ctx.path(key)
        if p and os.path.isfile(p):
            add(ctx.rel(p), read_text(p))
    pdir = ctx.path("PIPELINE_DIR")
    if pdir and os.path.isfile(os.path.join(pdir, SHIP_REPORT_NAME)):
        add(SHIP_REPORT_NAME, read_text(os.path.join(pdir, SHIP_REPORT_NAME)))
    return cites


def check_decisions(ctx):
    n, name = 8, "decisions"
    entries, p = decisions_entries(ctx)
    if p is None or not os.path.isfile(p or ""):
        return bad(n, name, "DECISIONS.md not found under CONTEXT_DIR")
    problems, warns = [], []
    ids = set()
    for e in entries:
        if e["id"] in ids:
            problems.append("%s appears twice --- ids are permanent and never "
                            "reused" % e["id"])
        ids.add(e["id"])
        if not e["name"]:
            problems.append("%s has no name (CONTRACT.md 7.3: `## DEC-nnn "
                            "· <name>`)" % e["id"])
        for field in REQUIRED_DEC_FIELDS:
            if ("**%s**" % field) not in e["text"]:
                problems.append("%s is missing the **%s** field" % (e["id"], field))
        status = ""
        ms = re.search(r"\*\*Status\.\*\*\s*([^\n]*)", e["text"])
        if ms:
            status = ms.group(1).strip()
            if not (status.upper().startswith("ACTIVE") or
                    re.match(r"^SUPERSEDED by DEC-\d{3,}", status, re.I)):
                problems.append("%s Status is %r; expected ACTIVE or "
                                "'SUPERSEDED by DEC-mmm'" % (e["id"], status))
        msim = re.search(r"\*\*Simulated\.\*\*\s*([^\n]*)", e["text"])
        if msim and not SIMULATED_RE.search(msim.group(1)):
            problems.append("%s Simulated line does not state the replay: %r --- "
                            "'I considered it' is not a simulation"
                            % (e["id"], msim.group(1).strip()))
        msup = re.search(r"\*\*Supersedes\.\*\*\s*(DEC-\d{3,})", e["text"])
        if msup and msup.group(1) not in [x["id"] for x in entries]:
            problems.append("%s supersedes %s, which does not resolve in this file"
                            % (e["id"], msup.group(1)))
    for dec, wheres in sorted(cited_dec_ids(ctx).items()):
        if dec not in ids:
            problems.append("%s is cited (%s) but resolves to nothing --- a "
                            "citation that resolves to nothing still reads as "
                            "though it resolves"
                            % (dec, ", ".join(sorted(wheres))[:80]))
    nlines = len(read_text(p).split("\n"))
    soft = ctx.num("DECISIONS_HOT_SOFT_LINES")
    hard = ctx.num("DECISIONS_HOT_HARD_LINES")
    rollover = False
    if hard is not None and nlines > hard:
        rollover = True
        warns.append("ROLLOVER-REQUIRED: DECISIONS.md is %d lines (hard cap %d). "
                     "Recording a decision must never be the failing action --- "
                     "this is a WARN; retro proposes the rollover." % (nlines, hard))
    elif soft is not None and nlines > soft:
        warns.append("DECISIONS.md is %d lines (soft cap %d); rollover is due"
                     % (nlines, soft))
    if problems:
        r = bad(n, name, "; ".join(problems), problems + warns)
        return r
    if warns:
        return warn(n, name, " ".join(warns))
    return ok(n, name, "%d entr(ies) well-formed; every cited DEC id resolves; "
                       "%d lines (soft %s / hard %s)"
              % (len(entries), nlines, soft, hard))


# ---------------------------------------------------------------------------
# 9  ship-consent
# ---------------------------------------------------------------------------
def check_ship_consent(ctx):
    n, name = 9, "ship-consent"
    p = ctx.path("SHIP_CONSENT")
    if not p or not os.path.isfile(p):
        return skip(n, name, "no ship-consent record: no merge in progress. The "
                             "guard refuses the merge without one; this checker "
                             "does not create consent.")
    try:
        data = json.loads(read_text(p))
    except ValueError:
        return bad(n, name, "ship-consent.json is not valid JSON")
    problems = []
    required = ["pr", "head_sha", "base", "question", "options_offered", "answer",
                "answered_at"]
    for k in required:
        if k not in data or data[k] in ("", None, []):
            problems.append("missing field %r" % k)
    head = ctx.head()
    if head and data.get("head_sha") != head:
        problems.append("consent head_sha %s != HEAD %s --- consent was recorded "
                        "for a different commit"
                        % (str(data.get("head_sha"))[:12], head[:12]))
    base = (ctx.cfg.get("BASE_BRANCH") or "").strip()
    if base and data.get("base") != base:
        problems.append("consent base %r != BASE_BRANCH %r" % (data.get("base"), base))
    opts = data.get("options_offered") or []
    ans = data.get("answer") or ""
    if isinstance(opts, list) and opts and ans not in opts:
        problems.append("answer %r is not one of the options offered" % ans)
    if isinstance(opts, list) and len(opts) < 2:
        problems.append("fewer than two options offered --- 'proceed or don't' is "
                        "not a card")
    if ans and not re.match(r"^\s*yes\b", ans, re.I):
        problems.append("answer %r is not affirmative; nothing may merge on it" % ans)
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    return ok(n, name, "consent recorded for PR %s at HEAD %s (record, not control "
                       "--- branch protection is the control)"
              % (data.get("pr"), str(data.get("head_sha"))[:12]))


# ---------------------------------------------------------------------------
# 10  checkpoints
# ---------------------------------------------------------------------------
def mandatory_stages():
    env = (os.environ.get("RATCHET_MANDATORY_CHECKPOINTS") or "").strip()
    if env:
        return [s for s in re.split(r"[\s,]+", env) if s]
    return list(MANDATORY_CHECKPOINT_STAGES)


def check_checkpoints(ctx):
    n, name = 10, "checkpoints"
    d = ctx.path("CHECKPOINTS_DIR")
    if not d or not os.path.isdir(d):
        return bad(n, name, "checkpoints directory missing (%s): no mandatory FULL "
                            "checkpoint can be evidenced"
                   % (ctx.cfg.get("CHECKPOINTS_DIR") or "unset"))
    files = sorted(os.listdir(d))
    problems = []
    seen = []
    for stage in mandatory_stages():
        jumps = [f for f in files
                 if f.endswith("-jump.md") and stage in f.lower()]
        if not jumps:
            problems.append("no FULL checkpoint for the mandatory '%s' stage "
                            "(expected <n>-%s*-jump.md)" % (stage, stage))
            continue
        latest = sorted(jumps)[-1]
        prefix = latest[:-len("-jump.md")]
        clear = os.path.join(d, prefix + "-clear.md")
        evidence = os.path.join(d, prefix + "-evidence.txt")
        if not os.path.isfile(clear):
            problems.append("%s has a scribe summary but no clear-reviewer verdict "
                            "file (%s-clear.md) --- a checkpoint the judge never "
                            "wrote is not a checkpoint" % (prefix, prefix))
            continue
        if not os.path.isfile(evidence):
            problems.append("%s has no script-written evidence file "
                            "(%s-evidence.txt)" % (prefix, prefix))
        lines = [l.strip() for l in read_text(clear).split("\n") if l.strip()]
        if not lines:
            problems.append("%s-clear.md is empty" % prefix)
            continue
        final = lines[-1]
        if not VERDICT_RE.match(final):
            problems.append("%s-clear.md final line is %r; the verdict token must "
                            "stand alone as CLEAR / 'BLOCK: <reasons>' / "
                            "'ESCALATE: <reason>'" % (prefix, final[:60]))
        elif final != "CLEAR":
            problems.append("%s is %s --- proceed only on CLEAR"
                            % (prefix, final[:60]))
        else:
            seen.append(prefix)
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    return ok(n, name, "%d mandatory FULL checkpoint(s) CLEAR with their own verdict "
                       "files: %s" % (len(seen), ", ".join(seen)))


# ---------------------------------------------------------------------------
# 11  context-current
# ---------------------------------------------------------------------------
def check_context_current(ctx):
    n, name = 11, "context-current"
    start_p = ctx.path("RUN_START")
    start = None
    if start_p and os.path.isfile(start_p):
        try:
            start = int(float(read_text(start_p).strip().split("\n")[0]))
        except ValueError:
            start = None
    problems = []
    for key in ("CONTEXT_LIVE", "RUN_JOURNAL"):
        p = ctx.path(key)
        if not p:
            problems.append("%s unset in config" % key)
            continue
        if not os.path.isfile(p):
            problems.append("%s missing (%s)" % (key, ctx.rel(p)))
            continue
        if start is not None and os.path.getmtime(p) < start:
            problems.append("%s (%s) has not been touched since the run started "
                            "--- it is stale working state"
                            % (key, ctx.rel(p)))
    milestone = ctx.milestone()
    jp = ctx.path("RUN_JOURNAL")
    warns = []
    if milestone and jp and os.path.isfile(jp) and \
            milestone not in read_text(jp):
        warns.append("run journal never names the active milestone %s" % milestone)
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    if warns:
        return warn(n, name, "; ".join(warns))
    return ok(n, name, "context-live and run-journal both updated this run")


# ---------------------------------------------------------------------------
# 12  narrative
# ---------------------------------------------------------------------------
def check_narrative(ctx):
    n, name = 12, "narrative"
    nar = ctx.narrative()
    if nar.get("error"):
        return bad(n, name, "check_narrative.py could not run: %s" % nar["error"])
    hits = [v for v in nar["violations"] if v["check"] not in RATIONALE_CHECKS]
    if hits:
        return bad(n, name,
                   "%d narrative violation(s): %s"
                   % (len(hits), "; ".join("%s %s (%s)"
                                           % (v["check"], v["site"], v["detail"])
                                           for v in hits[:6])),
                   [v["detail"] for v in hits])
    return ok(n, name, "no decision told twice, no probe transcript in a ledger "
                       "cell, every narrative artifact inside its cap")


# ---------------------------------------------------------------------------
# 13  escalations
# ---------------------------------------------------------------------------
def escalation_records(ctx):
    """Records from ESCALATION_LEDGER (jsonl) and ESCALATIONS_DIR/*.json."""
    recs = []
    led = ctx.path("ESCALATION_LEDGER")
    if led and os.path.isfile(led):
        for i, line in enumerate(read_text(led).split("\n"), start=1):
            s = line.strip()
            if not s:
                continue
            try:
                obj = json.loads(s)
            except ValueError:
                recs.append({"__malformed__": True, "where": "ledger:%d" % i})
                continue
            obj["where"] = "ledger:%d" % i
            recs.append(obj)
    d = ctx.path("ESCALATIONS_DIR")
    if d and os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json"):
                continue
            p = os.path.join(d, fn)
            try:
                obj = json.loads(read_text(p))
            except ValueError:
                recs.append({"__malformed__": True, "where": fn})
                continue
            if isinstance(obj, dict):
                obj["where"] = fn
                recs.append(obj)
    return recs


def check_escalations(ctx):
    n, name = 13, "escalations"
    recs = escalation_records(ctx)
    d = ctx.path("ESCALATIONS_DIR")
    problems, warns = [], []

    # a control-layer postcondition left pending is a state in which no later
    # refusal can be trusted --- fail closed on it.
    if d and os.path.isdir(d):
        pend = os.path.join(d, "postcondition-pending")
        if os.path.isfile(pend):
            problems.append("control-layer postcondition still pending (%s): %s"
                            % (ctx.rel(pend),
                               read_text(pend).strip()[:120] or "(no detail)"))
    for r in recs:
        if r.get("__malformed__"):
            problems.append("unparseable escalation record at %s" % r.get("where"))
            continue
        st = str(r.get("postcondition_status") or "").lower()
        if r.get("postcondition") and st not in ("satisfied", "n/a", "none"):
            problems.append("escalation %s left postcondition %r %s"
                            % (r.get("id", "?"), r.get("postcondition"),
                               st or "unrecorded"))
    if not recs:
        return ok(n, name, "no escalations this run; no control-layer postcondition "
                           "pending")

    rules = sorted(set(str(r.get("rule") or r.get("rule_id") or "")
                       for r in recs if not r.get("__malformed__")))
    rules = [r for r in rules if r]
    never = None
    rc, out = ctx.esc_call("rt_esc_never_list")
    if rc == 0:
        never = set(x.strip() for x in out.split("\n") if x.strip())
    for rule in rules:
        if never is not None:
            is_never = rule in never
        else:
            rc2, _ = ctx.esc_call("rt_esc_never_escalatable", rule)
            if rc2 in (8, 9, 10):
                problems.append("escalation-lib.sh does not expose the "
                                "never-escalatable table (rt_esc_never_list / "
                                "rt_esc_never_escalatable); %d escalation(s) cannot "
                                "be audited --- failing closed" % len(recs))
                break
            is_never = (rc2 == 0)
        if is_never:
            problems.append("escalation of rule %r was recorded, but that rule is "
                            "NEVER escalatable --- nothing lifts it, not an "
                            "approval, not a card" % rule)
    counts = {}
    for r in recs:
        k = str(r.get("rule") or r.get("rule_id") or "")
        if k:
            counts[k] = counts.get(k, 0) + 1
    for k, v in sorted(counts.items()):
        if v >= 2:
            warns.append("rule %r escalated %d times --- asking twice is evidence "
                         "the rule is miscalibrated; that is a refinement row in "
                         "the retro, not a third request" % (k, v))
    if problems:
        return bad(n, name, "; ".join(problems), problems + warns)
    if warns:
        return warn(n, name, " ".join(warns))
    return ok(n, name, "%d escalation(s) audited against the never-escalatable "
                       "table; no control-layer postcondition pending" % len(recs))


# ---------------------------------------------------------------------------
# 14  lessons  (includes the deep must-fix-recurred-with-green-assert check)
# ---------------------------------------------------------------------------
TEST_LINE_RE = re.compile(
    r"^\s*[-*]?\s*(?:named\s+test|test|asserted\s+by|assert)\s*[:=]\s*(.+)$", re.I)


def parse_lessons(ctx):
    p = ctx.path("ACTIVE_LESSONS")
    if not p or not os.path.isfile(p):
        return [], p
    text = read_text(p)
    lessons, cur = [], None
    for i, line in enumerate(text.split("\n"), start=1):
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            if cur:
                lessons.append(cur)
            head = m.group(1)
            nm = re.match(r"^[`*]*([a-z][a-z0-9-]*)[`*]*", head)
            cur = {"heading": head, "name": nm.group(1) if nm else head,
                   "line": i, "body": []}
        elif cur is not None:
            cur["body"].append(line)
    if cur:
        lessons.append(cur)
    for l in lessons:
        body = "\n".join(l["body"])
        l["text"] = body
        l["must_fix"] = bool(re.search(r"\bMUST-FIX\b", body + " " + l["heading"]))
        test = ""
        for line in l["body"]:
            m = TEST_LINE_RE.match(line)
            if m:
                test = m.group(1).strip().strip("`").strip()
                break
        l["test"] = test
        mr = re.search(r"recurrence\s*[:=]\s*(\d+)", body, re.I)
        l["recurrence"] = int(mr.group(1)) if mr else None
        l["recurred_lines"] = re.findall(r"recurred[- ]in\s*[:=]\s*(.+)", body, re.I)
    return lessons, p


def lessons_recurred_this_run(ctx):
    """Names flagged as having recurred in THIS run (events log is authoritative)."""
    names = set()
    p = ctx.path("EVENTS_LOG")
    token = None
    m = ctx.metrics()
    if isinstance(m, dict):
        token = m.get("run")
    if p and os.path.isfile(p):
        for line in read_text(p).split("\n"):
            s = line.strip()
            if not s:
                continue
            try:
                obj = json.loads(s)
            except ValueError:
                continue
            if obj.get("type") != "lesson_recurred":
                continue
            r = (obj.get("run") or "").strip()
            if r and token and r != token:
                continue
            kv = obj.get("kv") or {}
            nm = str(kv.get("name") or kv.get("lesson") or "").strip()
            if nm:
                names.add(nm)
    lessons, _ = parse_lessons(ctx)
    for l in lessons:
        for r in l["recurred_lines"]:
            if token and token.split("@")[0] and \
                    (token in r or (ctx.milestone() and ctx.milestone() in r)):
                names.add(l["name"])
    return names


def failing_tests_from_verify(ctx):
    """Test ids the last gate run reported as failing, plus overall greenness."""
    p = ctx.path("VERIFY_LAST")
    if not p or not os.path.isfile(p):
        return None, None
    try:
        data = json.loads(read_text(p))
    except ValueError:
        return None, None
    tail = data.get("tail") or ""
    try:
        rc = int(data.get("exit"))
    except (TypeError, ValueError):
        rc = None
    failing = set()
    pattern = (ctx.cfg.get("FAILURE_LINE_REGEX") or "").strip()
    for line in tail.split("\n"):
        hit = False
        if pattern:
            try:
                hit = bool(re.search(pattern, line))
            except re.error:
                hit = False
        if not hit:
            hit = bool(re.search(r"\b(FAILED|ERROR|FAIL)\b", line))
        if hit:
            for tok in re.findall(r"[\w./\\-]+(?:::[\w\[\]./-]+)+", line):
                failing.add(tok.strip())
            for tok in re.findall(r"[\w./-]+\.\w+::[\w\[\]-]+", line):
                failing.add(tok.strip())
    return rc, failing


def check_lessons(ctx):
    n, name = 14, "lessons"
    lessons, p = parse_lessons(ctx)
    if p is None or not os.path.isfile(p or ""):
        return bad(n, name, "ACTIVE-LESSONS.md missing (%s) --- it is the only retro "
                            "artifact any agent reads"
                   % (ctx.cfg.get("ACTIVE_LESSONS") or "unset"))
    must = [l for l in lessons if l["must_fix"]]
    problems, warns = [], []
    for l in must:
        if not l["test"]:
            problems.append("MUST-FIX lesson %r names no test (expected a "
                            "`Test: <id>` line) --- a MUST-FIX with nothing "
                            "asserting it is a diary entry" % l["name"])
    rc, failing = failing_tests_from_verify(ctx)
    recurred = lessons_recurred_this_run(ctx)
    for l in must:
        if not l["test"]:
            continue
        if rc is None:
            warns.append("no gate artifact: cannot tell whether %r's test is green"
                         % l["name"])
            continue
        tid = l["test"]
        is_failing = any(tid in f or f in tid for f in (failing or set()))
        green = (not is_failing)
        if green and l["name"] in recurred:
            # THE DEEP ONE: the assertion passes and the lesson happened anyway,
            # so the test does not assert what the lesson says it asserts.
            problems.append(
                "must-fix-recurred-with-green-assert: MUST-FIX lesson %r recurred "
                "this run, yet its named test %r is GREEN. A green assertion beside "
                "a live recurrence means the test does not assert the lesson --- "
                "the lesson is unguarded, not fixed." % (l["name"], tid))
    if problems:
        return bad(n, name, "; ".join(problems), problems + warns)
    if warns:
        return warn(n, name, "; ".join(warns))
    return ok(n, name, "%d MUST-FIX lesson(s), each naming a test; none recurred "
                       "this run behind a green assertion" % len(must))


# ---------------------------------------------------------------------------
# 15  metrics
# ---------------------------------------------------------------------------
def check_metrics(ctx):
    n, name = 15, "metrics"
    m = ctx.metrics()
    if m.get("error"):
        return bad(n, name, "run_metrics.py could not run: %s" % m["error"])
    cons = m.get("contradictions") or []
    if cons:
        return bad(n, name,
                   "%d cross-counter contradiction(s): %s"
                   % (len(cons), "; ".join("%s (%s)" % (c["name"], c["detail"])
                                           for c in cons)),
                   [c["detail"] for c in cons])
    notes = m.get("notes") or {}
    if notes.get("events_malformed"):
        return warn(n, name, "%d malformed event line(s) in the events log"
                    % notes["events_malformed"])
    return ok(n, name, "counters internally consistent (run %s, %s event(s); null "
                       "means not instrumented, 0 means measured zero)"
              % (m.get("run"), notes.get("events_this_run")))


# ---------------------------------------------------------------------------
# 16  recap
# ---------------------------------------------------------------------------
def check_recap(ctx):
    n, name = 16, "recap"
    p = ctx.path("RECAP")
    if not p:
        return bad(n, name, "RECAP unset in ratchet.config.sh")
    if not os.path.isfile(p):
        if ctx.tier != "ship":
            return skip(n, name, "intermediate tier: recap is written before the "
                                 "Ship Prompt")
        return bad(n, name, "recap missing at %s --- the human-facing account of "
                            "the run" % ctx.rel(p))
    text = read_text(p)
    heads = [re.sub(r"^##\s*", "", l).strip()
             for l in text.split("\n") if re.match(r"^##\s+\S", l)]
    if heads != RECAP_HEADINGS:
        return bad(n, name, "recap headings are %s but CONTRACT.md 7.8 freezes "
                            "exactly these five in order: %s"
                   % (heads or "(none)", RECAP_HEADINGS))
    cap = ctx.num("CAP_RECAP_WORDS")
    wc = word_count(text)
    if cap is not None and wc > cap:
        return bad(n, name, "recap is %d words (cap CAP_RECAP_WORDS=%d)" % (wc, cap))
    return ok(n, name, "five headings in order, %d words (cap %s)" % (wc, cap))


# ---------------------------------------------------------------------------
# 17  naming
# ---------------------------------------------------------------------------
def filed_names(ctx):
    """Names as FILED (not cited) in each register -> {name: [registers]}."""
    reg = {}

    def add(nm, where):
        nm = (nm or "").strip().strip("`")
        if not nm:
            return
        reg.setdefault(nm, []).append(where)

    header, rows, fp = parse_ledger(ctx)
    if header:
        for lineno, cells in rows:
            add(ledger_cell(cells, header, "name"), "findings:%d" % lineno)
    lessons, lp = parse_lessons(ctx)
    for l in lessons:
        add(l["name"], "lessons:%d" % l["line"])
    pp = ctx.path("PENDING_ACTIONS")
    if pp and os.path.isfile(pp):
        for i, line in enumerate(read_text(pp).split("\n"), start=1):
            m = re.match(r"^##\s+[`*]*([a-z][a-z0-9-]*)[`*]*", line)
            if m:
                add(m.group(1), "pending:%d" % i)
                continue
            m = re.match(r"^[-*]\s+\[[ xX]\]\s+[`*]*([a-z][a-z0-9-]*)[`*]*\s*[—:-]",
                         line)
            if m:
                add(m.group(1), "pending:%d" % i)
    entries, dp = decisions_entries(ctx)
    for e in entries:
        if e["name"]:
            add(re.sub(r"[`*]", "", e["name"]).strip(), "decisions:%d" % e["line"])
    return reg


def check_naming(ctx):
    n, name = 17, "naming"
    reg = filed_names(ctx)
    if not reg:
        return warn(n, name, "no filed names found in findings / lessons / pending "
                             "/ decisions --- nothing to validate")
    script = ctx.sibling("check_narrative.py")
    if not os.path.isfile(script):
        return bad(n, name, "check_narrative.py missing; names cannot be validated "
                            "against the one implementation of the doctrine")
    tmp = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                      encoding="utf-8")
    try:
        tmp.write("\n".join(sorted(reg.keys())) + "\n")
        tmp.close()
        proc = subprocess.run(
            [sys.executable, script, "--repo-root", ctx.root,
             "--names-file", tmp.name, "--json"],
            capture_output=True, text=True, timeout=120,
            env=dict(os.environ, CLAUDE_PROJECT_DIR=ctx.root))
        try:
            data = json.loads(proc.stdout or "{}")
        except ValueError:
            data = {}
    finally:
        os.unlink(tmp.name)
    problems = []
    for r in data.get("names", []):
        if not r.get("valid"):
            problems.append("%r (%s) is not a valid name [%s] --- CONTRACT.md 6: "
                            "kebab-case, 2-5 words, states the problem"
                            % (r["name"], ", ".join(reg.get(r["name"], [])),
                               r.get("reason")))
    for nm, wheres in sorted(reg.items()):
        registers = set(w.split(":")[0] for w in wheres)
        if len(wheres) > 1:
            problems.append("%r is filed %d times (%s) --- names are permanent, "
                            "never reused; a superseding item gets a NEW name plus "
                            "a Supersedes line"
                            % (nm, len(wheres), ", ".join(wheres)))
        elif len(registers) > 1:
            problems.append("%r is filed in more than one register (%s)"
                            % (nm, ", ".join(sorted(registers))))
    if problems:
        return bad(n, name, "; ".join(problems), problems)
    return ok(n, name, "%d filed name(s) valid and unique across findings, lessons, "
                       "pending actions and decisions" % len(reg))


# ---------------------------------------------------------------------------
# Registry / runner
# ---------------------------------------------------------------------------
CHECKS = [
    (1, "gate-artifact", "VERIFY_LAST exists, matches HEAD and tier, exit 0",
     check_gate_artifact),
    (2, "manifest-scope", "changed files subset of plan-files + amendments",
     check_manifest_scope),
    (3, "win-rows", "WIN rows evidenced; proof map at HEAD; >=1 test per row",
     check_win_rows),
    (4, "findings-ledger", "ledger parses, frozen header, rows == findings filed",
     check_findings_ledger),
    (5, "rationale-caps", "FIXED <=40w; ACCEPTED/DEFERRED/WAIVED <=80w + DEC id",
     check_rationale_caps),
    (6, "criticals", "zero unresolved CRITICAL findings", check_criticals),
    (7, "ship-report", "required sections present", check_ship_report),
    (8, "decisions", "entries well-formed, DEC ids resolve, hot-file caps",
     check_decisions),
    (9, "ship-consent", "consent present and matching when merging",
     check_ship_consent),
    (10, "checkpoints", "mandatory FULL checkpoints: summary + own verdict + token",
     check_checkpoints),
    (11, "context-current", "context-live and run-journal updated this run",
     check_context_current),
    (12, "narrative", "one-home rule, probe transcripts, narrative caps",
     check_narrative),
    (13, "escalations", "escalations audited; no control-layer postcondition pending",
     check_escalations),
    (14, "lessons", "MUST-FIX lessons name a test; none recurred behind a green "
                    "assertion", check_lessons),
    (15, "metrics", "cross-counter contradiction detection", check_metrics),
    (16, "recap", "five frozen headings in order, under the word cap", check_recap),
    (17, "naming", "filed names valid per doctrine and unique across registers",
     check_naming),
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
    _w(os.path.join(root, ".agent-development", "ACTIVE-LESSONS.md"),
       "# Active lessons\n\n## dispatch-glob-missing-degrades-gate\n"
       "Status: MUST-FIX\nRecurrence: 3\n"
       "Test: tests/test_gate.py::test_head_match\n")
    _w(os.path.join(root, ".agent-development", "PENDING-HUMAN-ACTIONS.md"),
       "# Pending\n\n## rotate-escalation-key\nOwner: human\n")
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


def _mut_win_rows(root):
    os.unlink(os.path.join(root, "docs", "evidence", "M1", "win-01.txt"))


def _mut_findings_ledger(root):
    p = os.path.join(root, ".pipeline", "findings.md")
    _w(p, read_text(p) + "| unfiled-extra-row | reviewer | LOW | a.py:1 | extra | "
                         "FIXED | tidy | DEC-004 |\n")


def _mut_rationale_caps(root):
    p = os.path.join(root, ".pipeline", "findings.md")
    long_rationale = " ".join(["word"] * 60)
    _w(p, read_text(p).replace("corrected in the gate", long_rationale))


def _mut_criticals(root):
    p = os.path.join(root, ".pipeline", "findings.md")
    _w(p, read_text(p).replace("| ledger-count-drifts | security | MEDIUM |",
                               "| ledger-count-drifts | security | CRITICAL |"))


def _mut_ship_report(root):
    p = os.path.join(root, ".pipeline", "ship-report.md")
    _w(p, read_text(p).replace("## Checkpoint ledger\nx\n", ""))


def _mut_decisions(root):
    p = os.path.join(root, ".context", "DECISIONS.md")
    _w(p, read_text(p).replace(
        "**Simulated.** Simulated against 3 frozen rows; none changed.\n", ""))


def _mut_ship_consent(root):
    _w(os.path.join(root, ".pipeline", "ship-consent.json"),
       json.dumps({"pr": 42, "head_sha": "f" * 40, "base": "main",
                   "question": "Merge agent/m1 into main? (PR #42)",
                   "options_offered": ["Yes --- merge (Recommended)",
                                       "No --- hold the PR open"],
                   "answer": "Yes --- merge (Recommended)",
                   "answered_at": "2026-08-20T00:00:00Z"}))


def _mut_checkpoints(root):
    p = os.path.join(root, ".pipeline", "checkpoints", "1-security-clear.md")
    _w(p, "Read the summary.\nLooks good to me\n")


def _mut_context_current(root):
    p = os.path.join(root, ".pipeline", "context-live.md")
    old = int(datetime.datetime.now().timestamp() - 86400)
    os.utime(p, (old, old))


def _mut_narrative(root):
    _w(os.path.join(root, ".pipeline", "context-live.md"),
       "# Live\nM1 in flight. DEC-004 was taken because the proof map used to be "
       "hand-maintained and drifted from its own selector. We debated three "
       "alternatives. The third won, and here is the whole argument again.\n")


def _mut_escalations(root):
    _w(os.path.join(root, ".pipeline", "escalations", "ledger.jsonl"),
       json.dumps({"id": "esc-2", "rule": "secrets", "state": "requested"}) + "\n")


def _mut_lessons(root):
    _w(os.path.join(root, ".pipeline", "run-events.jsonl"),
       json.dumps({"ts": 1, "type": "lesson_recurred",
                   "kv": {"name": "dispatch-glob-missing-degrades-gate"}}) + "\n")


def _mut_metrics(root):
    _w(os.path.join(root, ".pipeline", "run-events.jsonl"),
       "\n".join([
           json.dumps({"ts": 1, "type": "gate_block", "kv": {"gate": "stop"}}),
           json.dumps({"ts": 2, "type": "gate_block", "kv": {"gate": "stop"}}),
           json.dumps({"ts": 3, "type": "instrument",
                       "kv": {"counter": "dispatches_total"}}),
       ]) + "\n")


def _mut_recap(root):
    p = os.path.join(root, ".pipeline", "recap.md")
    _w(p, read_text(p).replace("## What's next", "## Next steps"))


def _mut_naming(root):
    p = os.path.join(root, ".pipeline", "findings.md")
    _w(p, read_text(p).replace("gate-blames-wrong-actor", "fix-issue"))


MUTATORS = {
    "gate-artifact": _mut_gate_artifact,
    "manifest-scope": _mut_manifest_scope,
    "win-rows": _mut_win_rows,
    "findings-ledger": _mut_findings_ledger,
    "rationale-caps": _mut_rationale_caps,
    "criticals": _mut_criticals,
    "ship-report": _mut_ship_report,
    "decisions": _mut_decisions,
    "ship-consent": _mut_ship_consent,
    "checkpoints": _mut_checkpoints,
    "context-current": _mut_context_current,
    "narrative": _mut_narrative,
    "escalations": _mut_escalations,
    "lessons": _mut_lessons,
    "metrics": _mut_metrics,
    "recap": _mut_recap,
    "naming": _mut_naming,
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

        # --- 3. the deep lessons check names the right defect --------------
        root = os.path.join(tmp, "bad-lessons")
        c = make_ctx(repo_root=root, tier="ship")
        r = run_checks(c, only="lessons")[0]
        if "must-fix-recurred-with-green-assert" not in r.detail:
            ok_all = False
            print("SELFTEST FAIL: lessons check must report "
                  "must-fix-recurred-with-green-assert; got %s" % r.detail)

        # --- 4. a disclosure renders DISCLOSED, never PASS, and clears exit -
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
