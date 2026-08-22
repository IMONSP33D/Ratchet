#!/usr/bin/env python3
# =============================================================================
# run_metrics.py --- roll EVENTS_LOG into METRICS_JSON and render the retro's
# mechanical record (CONTRACT.md 7.9, 7.10).
#
# THE CONVENTION THAT MATTERS: **null is not zero.**
#   null  = this counter was never instrumented --- nothing measured it.
#   0     = it WAS instrumented and the measured value is zero.
# A counter is "instrumented" when either (a) at least one event that feeds it
# appears in this run's log, or (b) an explicit
#   {"type":"instrument","kv":{"counter":"<name>"}}
# event declares it. Everything else stays null, renders as an em dash in the
# markdown, and is EXCLUDED from every cross-counter comparison --- you cannot
# contradict a measurement nobody took.
#
# PER-RUN SCOPING: every counter is scoped to the CURRENT run token. Events
# carrying a different token are ignored and reported as `events_other_run`;
# an existing METRICS_JSON written under a different token is rebuilt from
# scratch, never merged. A retro must never quote a previous run's numbers
# AS ITS OWN -- this file will never compute a cross-run delta for a live run.
#
# WRITER/READER CONTRACT for METRICS_JSON (this file owns both ends):
#   {"schema":1,"run":"<token>","milestone":"M<n>","generated_at":"<iso>",
#    "counters":{"<name>": <int|null>, ...},
#    "maps":{"<name>": {"<key>": <int>}},
#    "end_state":{...}|null, "notes":{...}, "contradictions":[{...}]}
#
# METRICS SIDECARS ($DEV_DIR/metrics/NNN-<milestone>.json) are a different,
# permanent thing: one snapshot per retro, written by `--out` pointed there,
# never pruned. `--trend [N]` reads back N of them (oldest first) for a
# read-only human-facing "last N runs" table -- the one place a comparison
# ACROSS runs is allowed, because nothing here claims it as a CURRENT run's
# own measurement. Writing the sidecar is the retro seat's job (retro.md §2);
# this file only provides the write target and the read-back.
#
# Stdlib only. utf-8 on every open. No project nouns.
#
# EXIT CODES
#   0  metrics rolled / rendered
#   1  --fail-on-contradiction was given and a cross-counter contradiction exists
#   2  usage error
#   3  environment error (config missing, unreadable events log)
# =============================================================================
"""Roll the Ratchet events log into run metrics and the retro's §2 table."""

import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import tempfile

CONFIG_KEYS = [
    "REPO_ROOT", "PIPELINE_DIR", "EVENTS_LOG", "METRICS_JSON", "RUN_ACTIVE",
    "RUN_START", "RUN_IDLE", "RUN_LAST_SEEN", "FINDINGS", "CHECKPOINTS_DIR",
    "BASE_BRANCH", "MAX_REVIEW_ROUNDS", "MAX_RUN_WORK_SECONDS",
    "MAX_RUN_WALL_SECONDS", "HOOKS_DIR", "DEV_DIR",
]

# name -> (event type, optional (kv-key, kv-value) filter, human label)
COUNTER_SPECS = [
    ("dispatches_total", "dispatch", None, "subagent dispatches"),
    ("gate_blocks_total", "gate_block", None, "gate blocks (all gates)"),
    ("stop_gate_blocks", "gate_block", ("gate", "stop"), "stop-gate blocks"),
    ("subagent_gate_blocks", "gate_block", ("gate", "subagent"),
     "subagent-gate blocks"),
    ("red_gate_blocks", "gate_block", ("gate", "red"), "red-gate blocks"),
    ("guard_refusals", "refusal", None, "guard refusals"),
    ("escalation_requests", "escalation_request", None, "escalation requests"),
    ("escalation_approvals", "escalation_approved", None, "escalation approvals"),
    ("disclosures", "disclosure", None, "disclosures granted"),
    ("decision_cards", "decision_card", None, "decision cards asked"),
    ("checkpoints_full", "checkpoint", ("kind", "full"), "FULL checkpoints"),
    ("checkpoints_fast", "checkpoint", ("kind", "fast"), "FAST checkpoints"),
    ("checkpoint_blocks", "checkpoint_verdict", ("verdict", "BLOCK"),
     "checkpoint BLOCK verdicts"),
    ("review_rounds", "review_round", None, "review-fix rounds"),
    ("findings_filed", "finding_filed", None, "findings filed"),
    ("verify_runs", "verify", None, "verify runs"),
    ("verify_failures", "verify", ("result", "fail"), "verify failures"),
    ("commits", "commit", None, "commits recorded by hooks"),
    ("lesson_recurrences", "lesson_recurred", None, "lessons that recurred"),
]

# maps: counter name -> (event type, kv key used as the map key)
MAP_SPECS = [
    ("dispatches_by_agent", "dispatch", "agent"),
    ("gate_blocks_by_gate", "gate_block", "gate"),
    ("refusals_by_rule", "refusal", "rule"),
    ("findings_by_severity", "finding_filed", "severity"),
]


class EnvError(Exception):
    """Fail closed --- exit 3."""


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


def load_config(hooks_dir, root, keys):
    cfg = os.path.join(hooks_dir, "ratchet.config.sh")
    if not os.path.isfile(cfg):
        raise EnvError("ratchet.config.sh not found at %s (fail closed)" % cfg)
    if not shutil.which("bash"):
        raise EnvError("bash not on PATH (fail closed)")
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = root
    proc = subprocess.run(["bash", "-c", _EXTRACT, "bash", cfg] + list(keys),
                          capture_output=True, text=True, timeout=60, env=env)
    if proc.returncode == 9:
        raise EnvError("could not source %s" % cfg)
    if proc.returncode != 0:
        raise EnvError("config extraction failed (%d)" % proc.returncode)
    out = {}
    for line in proc.stdout.replace("\r", "").split("\n"):
        if "\t" in line:
            k, v = line.split("\t", 1)
            out[k] = v
    return cfg, out


class Ctx(object):
    def __init__(self, hooks_dir, root, cfg_path, cfg):
        self.hooks_dir = hooks_dir
        self.root = root
        self.cfg_path = cfg_path
        self.cfg = cfg

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


def make_ctx(repo_root=None):
    hd = find_hooks_dir()
    root = repo_root or find_repo_root(hd)
    if repo_root:
        cand = os.path.join(repo_root, ".claude", "hooks")
        if os.path.isfile(os.path.join(cand, "ratchet.config.sh")):
            hd = cand
    cfg_path, cfg = load_config(hd, root, CONFIG_KEYS)
    cfg_root = (cfg.get("REPO_ROOT") or "").strip()
    if repo_root is None and cfg_root and os.path.isdir(cfg_root):
        root = os.path.abspath(cfg_root)
    return Ctx(hd, root, cfg_path, cfg)


def utc_now_iso():
    """UTC timestamp, 3.8-safe and without datetime.utcnow()'s deprecation."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().replace("\r\n", "\n").replace("\r", "\n")
    except (IOError, OSError):
        return ""


def git(root, *args):
    try:
        out = subprocess.run(["git"] + list(args), cwd=root, capture_output=True,
                             text=True, timeout=60)
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


# ---------------------------------------------------------------------------
# Run token --- prefer hooklib's rt_run_token so every component agrees.
# ---------------------------------------------------------------------------
def run_token(ctx):
    hooks = ctx.path("HOOKS_DIR") or ctx.hooks_dir
    lib = os.path.join(hooks, "hooklib.sh")
    if os.path.isfile(lib):
        try:
            proc = subprocess.run(
                ["bash", "-c",
                 '. "$1" >/dev/null 2>&1 || exit 9; '
                 'command -v rt_run_token >/dev/null 2>&1 || exit 8; rt_run_token',
                 "bash", lib],
                cwd=ctx.root, capture_output=True, text=True, timeout=60,
                stdin=subprocess.DEVNULL,
                env=dict(os.environ, CLAUDE_PROJECT_DIR=ctx.root))
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip().split("\n")[-1].strip()
        except Exception:
            pass
    milestone = milestone_of(ctx) or "none"
    start = read_text(ctx.path("RUN_START") or "").strip().split("\n")[0].strip()
    return "%s@%s" % (milestone, start or "unstarted")


def milestone_of(ctx):
    p = ctx.path("RUN_ACTIVE")
    if p and os.path.isfile(p):
        return read_text(p).strip().split("\n")[0].strip()
    return ""


# ---------------------------------------------------------------------------
# Event roll-up
# ---------------------------------------------------------------------------
def load_events(ctx):
    """Return (mine, other_run, unscoped, malformed)."""
    p = ctx.path("EVENTS_LOG")
    mine, other, unscoped, malformed = [], 0, 0, 0
    if not p or not os.path.isfile(p):
        return mine, other, unscoped, malformed
    token = run_token(ctx)
    for line in read_text(p).split("\n"):
        s = line.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
        except ValueError:
            malformed += 1
            continue
        if not isinstance(obj, dict):
            malformed += 1
            continue
        r = (obj.get("run") or "").strip()
        if not r:
            unscoped += 1
            mine.append(obj)
        elif r == token:
            mine.append(obj)
        else:
            other += 1
    return mine, other, unscoped, malformed


def kv_of(ev):
    kv = ev.get("kv")
    return kv if isinstance(kv, dict) else {}


def declared_instrumented(events):
    names = set()
    for ev in events:
        if ev.get("type") == "instrument":
            kv = kv_of(ev)
            for key in ("counter", "counters"):
                val = kv.get(key)
                if isinstance(val, str):
                    names.update([x.strip() for x in val.split(",") if x.strip()])
                elif isinstance(val, list):
                    names.update([str(x) for x in val])
    return names


def roll(ctx, events, other, unscoped, malformed):
    declared = declared_instrumented(events)
    types_seen = set(ev.get("type") for ev in events)

    counters = {}
    for name, etype, filt, _label in COUNTER_SPECS:
        instrumented = (etype in types_seen) or (name in declared)
        if not instrumented:
            counters[name] = None            # null: nobody measured this
            continue
        n = 0
        for ev in events:
            if ev.get("type") != etype:
                continue
            if filt:
                k, want = filt
                got = str(kv_of(ev).get(k, ""))
                if want == "BLOCK":
                    if not got.upper().startswith("BLOCK"):
                        continue
                elif got.lower() != want.lower():
                    continue
            n += 1
        counters[name] = n

    maps = {}
    for name, etype, key in MAP_SPECS:
        if etype not in types_seen:
            maps[name] = None
            continue
        bucket = {}
        for ev in events:
            if ev.get("type") != etype:
                continue
            k = str(kv_of(ev).get(key, "")) or "(unlabelled)"
            bucket[k] = bucket.get(k, 0) + 1
        maps[name] = bucket

    # time budget --- measured from the run lifecycle files, not from events
    counters["work_seconds"] = work_seconds(ctx)
    counters["wall_seconds"] = wall_seconds(ctx)
    # ledger rows are a direct measurement of the findings file
    counters["findings_ledger_rows"] = ledger_rows(ctx)
    counters["checkpoint_files"] = checkpoint_files(ctx)

    notes = {
        "events_this_run": len(events),
        "events_other_run": other,
        "events_unscoped": unscoped,
        "events_malformed": malformed,
        "run_scope": "partial" if unscoped else "exact",
        "declared_instrumented": sorted(declared),
        "null_means": "not instrumented; 0 means measured zero",
    }
    return counters, maps, notes


def _int_file(path):
    if not path or not os.path.isfile(path):
        return None
    s = read_text(path).strip().split("\n")[0].strip()
    try:
        return int(float(s))
    except ValueError:
        return None


def work_seconds(ctx):
    """(now - RUN_START) - RUN_IDLE. null when the run never started.

    NOTE: nothing here may edit RUN_START --- see CONTRACT.md 5.3. This is a
    read-only measurement; clearing a halt by rewriting the clock is forbidden.
    """
    start = _int_file(ctx.path("RUN_START"))
    if start is None:
        return None
    idle = _int_file(ctx.path("RUN_IDLE")) or 0
    now = int(datetime.datetime.now().timestamp())
    return max(0, (now - start) - idle)


def wall_seconds(ctx):
    start = _int_file(ctx.path("RUN_START"))
    if start is None:
        return None
    now = int(datetime.datetime.now().timestamp())
    return max(0, now - start)


def ledger_rows(ctx):
    p = ctx.path("FINDINGS")
    if not p or not os.path.isfile(p):
        return None
    n, header = 0, False
    for line in read_text(p).split("\n"):
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if not header:
            if cells and cells[0].lower() in ("name", "id"):
                header = True
            continue
        if all(re.match(r"^:?-{2,}:?$", c or "-") for c in cells):
            continue
        if len(cells) >= 2:
            n += 1
    return n if header else None


def checkpoint_files(ctx):
    d = ctx.path("CHECKPOINTS_DIR")
    if not d or not os.path.isdir(d):
        return None
    return len([f for f in os.listdir(d) if f.endswith("-jump.md")])


# ---------------------------------------------------------------------------
# End state --- git derived
# ---------------------------------------------------------------------------
def measure_end_state(ctx):
    root = ctx.root
    if not shutil.which("git") or not git(root, "rev-parse", "--git-dir"):
        return None
    base = (ctx.cfg.get("BASE_BRANCH") or "").strip() or "main"
    head = git(root, "rev-parse", "HEAD")
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    merge_base = git(root, "merge-base", base, "HEAD")
    commits = None
    files_changed = None
    insertions = deletions = None
    if merge_base:
        rev = git(root, "rev-list", "--count", "%s..HEAD" % merge_base)
        commits = int(rev) if rev.isdigit() else None
        names = git(root, "diff", "--name-only", "%s..HEAD" % merge_base)
        files_changed = len([l for l in names.split("\n") if l.strip()])
        stat = git(root, "diff", "--shortstat", "%s..HEAD" % merge_base)
        mi = re.search(r"(\d+) insertion", stat)
        md = re.search(r"(\d+) deletion", stat)
        insertions = int(mi.group(1)) if mi else 0
        deletions = int(md.group(1)) if md else 0
    dirty = git(root, "status", "--porcelain")
    return {
        "branch": branch or None,
        "base": base,
        "head_sha": head or None,
        "merge_base": merge_base or None,
        "commits_on_branch": commits,
        "files_changed": files_changed,
        "insertions": insertions,
        "deletions": deletions,
        "dirty_files": len([l for l in dirty.split("\n") if l.strip()]),
    }


# ---------------------------------------------------------------------------
# Cross-counter contradiction detection (consumed by check_done.py check 15)
# A null NEVER participates --- an unmeasured counter cannot contradict anything.
# ---------------------------------------------------------------------------
def contradictions(ctx, counters, end_state):
    out = []

    def add(name, detail):
        out.append({"name": name, "detail": detail})

    def val(k):
        return counters.get(k)

    def both(a, b):
        return val(a) is not None and val(b) is not None

    for k, v in counters.items():
        if isinstance(v, int) and v < 0:
            add("negative-counter", "%s = %d" % (k, v))

    if both("gate_blocks_total", "dispatches_total"):
        if val("gate_blocks_total") > 0 and val("dispatches_total") == 0:
            add("blocks-without-dispatches",
                "gate_blocks_total=%d beside dispatches_total=0 --- gates fired for "
                "work no dispatch counter saw" % val("gate_blocks_total"))
    if both("checkpoint_blocks", "checkpoints_full") and \
            counters.get("checkpoints_fast") is not None:
        if val("checkpoint_blocks") > 0 and \
                val("checkpoints_full") + val("checkpoints_fast") == 0:
            add("verdicts-without-checkpoints",
                "checkpoint_blocks=%d with zero checkpoints recorded"
                % val("checkpoint_blocks"))
    if both("findings_filed", "findings_ledger_rows"):
        if val("findings_filed") == 0 and val("findings_ledger_rows") > 0:
            add("ledger-rows-without-filings",
                "findings_ledger_rows=%d beside findings_filed=0"
                % val("findings_ledger_rows"))
    if both("verify_failures", "verify_runs") and \
            val("verify_failures") > val("verify_runs"):
        add("failures-exceed-runs", "verify_failures=%d > verify_runs=%d"
            % (val("verify_failures"), val("verify_runs")))
    if both("escalation_approvals", "escalation_requests") and \
            val("escalation_approvals") > val("escalation_requests"):
        add("approvals-exceed-requests",
            "escalation_approvals=%d > escalation_requests=%d"
            % (val("escalation_approvals"), val("escalation_requests")))
    if both("work_seconds", "wall_seconds") and \
            val("work_seconds") > val("wall_seconds"):
        add("work-exceeds-wall", "work_seconds=%d > wall_seconds=%d"
            % (val("work_seconds"), val("wall_seconds")))
    cap = ctx.num("MAX_REVIEW_ROUNDS")
    if cap is not None and val("review_rounds") is not None and \
            val("review_rounds") > cap:
        add("review-rounds-over-cap",
            "review_rounds=%d exceeds MAX_REVIEW_ROUNDS=%d"
            % (val("review_rounds"), cap))
    if end_state and end_state.get("files_changed") is not None and \
            val("commits") is not None:
        if val("commits") == 0 and end_state["files_changed"] > 0:
            add("changes-without-commits",
                "commits=0 beside %d changed file(s) on the branch"
                % end_state["files_changed"])
    return out


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def fmt(v):
    if v is None:
        return "--- *(not instrumented)*"
    if isinstance(v, int) and v == 0:
        return "0 *(measured)*"
    return str(v)


def render_markdown(metrics):
    c = metrics["counters"]
    lines = []
    lines.append("## 2. Mechanical record")
    lines.append("")
    lines.append("Generated by `.claude/hooks/run_metrics.py --markdown`; do not "
                 "hand-maintain. `---` means the counter was never instrumented; "
                 "`0 (measured)` means it was, and the answer was zero.")
    lines.append("")
    lines.append("run: `%s` &middot; milestone: `%s` &middot; generated: %s"
                 % (metrics["run"], metrics["milestone"] or "-",
                    metrics["generated_at"]))
    lines.append("")
    lines.append("| metric | value |")
    lines.append("|---|---|")
    labels = dict((n, l) for n, _t, _f, l in COUNTER_SPECS)
    labels.update({"work_seconds": "work seconds (idle folded out)",
                   "wall_seconds": "wall seconds",
                   "findings_ledger_rows": "findings ledger rows",
                   "checkpoint_files": "checkpoint jump summaries on disk"})
    for name in [n for n, _t, _f, _l in COUNTER_SPECS] + \
                ["work_seconds", "wall_seconds", "findings_ledger_rows",
                 "checkpoint_files"]:
        lines.append("| %s | %s |" % (labels.get(name, name), fmt(c.get(name))))
    lines.append("")
    for mname, bucket in sorted((metrics.get("maps") or {}).items()):
        lines.append("**%s**" % mname.replace("_", " "))
        lines.append("")
        if bucket is None:
            lines.append("- --- *(not instrumented)*")
        elif not bucket:
            lines.append("- *(measured: empty)*")
        else:
            for k in sorted(bucket):
                lines.append("- `%s`: %d" % (k, bucket[k]))
        lines.append("")
    es = metrics.get("end_state")
    lines.append("**End state**")
    lines.append("")
    if not es:
        lines.append("- --- *(not measured; run with `--measure-end-state`)*")
    else:
        for k in ("branch", "base", "head_sha", "commits_on_branch",
                  "files_changed", "insertions", "deletions", "dirty_files"):
            lines.append("- %s: %s" % (k.replace("_", " "), fmt(es.get(k))))
    lines.append("")
    notes = metrics.get("notes") or {}
    lines.append("**Scope**")
    lines.append("")
    lines.append("- events this run: %s" % fmt(notes.get("events_this_run")))
    lines.append("- events ignored (other run token): %s"
                 % fmt(notes.get("events_other_run")))
    lines.append("- events without a run token: %s"
                 % fmt(notes.get("events_unscoped")))
    lines.append("- malformed event lines: %s" % fmt(notes.get("events_malformed")))
    lines.append("")
    con = metrics.get("contradictions") or []
    lines.append("**Cross-counter contradictions**")
    lines.append("")
    if not con:
        lines.append("- none")
    else:
        for x in con:
            lines.append("- `%s`: %s" % (x["name"], x["detail"]))
    lines.append("")
    return "\n".join(lines)


def build(ctx, with_end_state=False):
    events, other, unscoped, malformed = load_events(ctx)
    counters, maps, notes = roll(ctx, events, other, unscoped, malformed)
    end_state = measure_end_state(ctx) if with_end_state else None
    metrics = {
        "schema": 1,
        "run": run_token(ctx),
        "milestone": milestone_of(ctx),
        "generated_at": utc_now_iso(),
        "counters": counters,
        "maps": maps,
        "end_state": end_state,
        "notes": notes,
    }
    metrics["contradictions"] = contradictions(ctx, counters, end_state)
    return metrics


def write_metrics(ctx, metrics, out=None):
    dest = out or ctx.path("METRICS_JSON")
    if not dest:
        raise EnvError("METRICS_JSON unset in ratchet.config.sh")
    # Never merge with a previous run's file --- rebuild in place.
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    return dest


# ---------------------------------------------------------------------------
# Metrics sidecars ($DEV_DIR/metrics/NNN-<milestone>.json) and --trend
# ---------------------------------------------------------------------------
SIDECAR_RE = re.compile(r"^(\d{3})-.+\.json$")

TREND_COLUMNS = [
    ("escalation_requests", "esc"),
    ("red_gate_blocks", "red-gate"),
    ("work_seconds", "work-s"),
]


def sidecar_dir(ctx):
    dev = ctx.path("DEV_DIR")
    return os.path.join(dev, "metrics") if dev else None


def load_sidecars(ctx, limit=None):
    """Read $DEV_DIR/metrics/NNN-<milestone>.json, oldest first. Unreadable or
    non-conforming files are skipped, not fatal -- a broken sidecar must never
    block the run that would otherwise write the next one."""
    d = sidecar_dir(ctx)
    if not d or not os.path.isdir(d):
        return []
    rows = []
    for name in sorted(os.listdir(d)):
        m = SIDECAR_RE.match(name)
        if not m:
            continue
        try:
            with open(os.path.join(d, name), "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (IOError, OSError, ValueError):
            continue
        rows.append((int(m.group(1)), name, data))
    rows.sort(key=lambda r: r[0])
    if limit:
        rows = rows[-limit:]
    return rows


def render_trend(ctx, limit=5):
    """The read-only human-facing trend view the sidecars exist for. This is
    NOT a substitute for --markdown in a retro -- a retro measures only its
    own run (see the module header); this is for a human asking 'how are the
    last N runs looking' outside of any single retro."""
    d = sidecar_dir(ctx) or "$DEV_DIR/metrics"
    rows = load_sidecars(ctx, limit=limit)
    if not rows:
        return ("no sidecars in %s yet -- nothing has been written there by "
                "`run_metrics.py --out` (retro.md §2 does this once per run)"
                % d)
    header = "%-32s" % "sidecar"
    for _, label in TREND_COLUMNS:
        header += " %10s" % label
    header += " %10s" % "milestone"
    lines = ["last %d run%s from %s (oldest first):"
             % (len(rows), "" if len(rows) == 1 else "s", d), "", header]
    for _nnn, name, data in rows:
        c = (data or {}).get("counters", {}) or {}
        line = "%-32s" % name
        for key, _label in TREND_COLUMNS:
            v = c.get(key)
            line += " %10s" % ("-" if v is None else str(v))
        line += " %10s" % ((data or {}).get("milestone") or "-")
        lines.append(line)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------
FIXTURE_CONFIG = """#!/usr/bin/env bash
# Selftest fixture config (not the shipped defaults).
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
PIPELINE_DIR=".pipeline"
EVENTS_LOG=".pipeline/run-events.jsonl"
METRICS_JSON=".pipeline/run-metrics.json"
RUN_ACTIVE=".pipeline/run-active"
RUN_START=".pipeline/run-start"
RUN_IDLE=".pipeline/run-idle"
RUN_LAST_SEEN=".pipeline/run-last-seen"
FINDINGS=".pipeline/findings.md"
CHECKPOINTS_DIR=".pipeline/checkpoints"
BASE_BRANCH="main"
MAX_REVIEW_ROUNDS=2
MAX_RUN_WORK_SECONDS=28800
MAX_RUN_WALL_SECONDS=604800
HOOKS_DIR=".claude/hooks"
DEV_DIR=".agent-development"
"""


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def selftest():
    ok = True
    tmp = tempfile.mkdtemp(prefix="ratchet-metrics-")
    try:
        def build_repo(name, events, start="1700000000"):
            root = os.path.join(tmp, name)
            _write(os.path.join(root, ".claude", "hooks", "ratchet.config.sh"),
                   FIXTURE_CONFIG)
            _write(os.path.join(root, ".pipeline", "run-active"), "M1\n")
            _write(os.path.join(root, ".pipeline", "run-start"), start + "\n")
            _write(os.path.join(root, ".pipeline", "run-idle"), "0\n")
            _write(os.path.join(root, ".pipeline", "run-events.jsonl"),
                   "\n".join(json.dumps(e) for e in events) + "\n")
            return root

        token = "M1@1700000000"
        clean_events = [
            {"ts": 1, "type": "dispatch", "run": token, "milestone": "M1",
             "kv": {"agent": "developer"}},
            {"ts": 2, "type": "dispatch", "run": token, "milestone": "M1",
             "kv": {"agent": "test-writer"}},
            {"ts": 3, "type": "gate_block", "run": token, "milestone": "M1",
             "kv": {"gate": "stop"}},
            {"ts": 4, "type": "instrument", "run": token, "milestone": "M1",
             "kv": {"counter": "decision_cards"}},
        ]
        root = build_repo("clean", clean_events)
        ctx = make_ctx(repo_root=root)
        m = build(ctx, with_end_state=False)
        c = m["counters"]
        if c["dispatches_total"] != 2:
            print("SELFTEST FAIL: dispatches_total=%r" % c["dispatches_total"])
            ok = False
        if c["decision_cards"] != 0:
            print("SELFTEST FAIL: declared-instrumented counter should be measured "
                  "zero, got %r" % c["decision_cards"])
            ok = False
        if c["guard_refusals"] is not None:
            print("SELFTEST FAIL: uninstrumented counter should be null, got %r"
                  % c["guard_refusals"])
            ok = False
        if m["contradictions"]:
            print("SELFTEST FAIL: clean fixture has contradictions: %s"
                  % m["contradictions"])
            ok = False
        md = render_markdown(m)
        if "*(not instrumented)*" not in md or "0 *(measured)*" not in md:
            print("SELFTEST FAIL: markdown must render null and measured-zero "
                  "differently")
            ok = False

        # FAIL case: gate blocks with zero dispatches (both instrumented)
        bad_events = [
            {"ts": 1, "type": "gate_block", "run": token, "kv": {"gate": "stop"}},
            {"ts": 2, "type": "gate_block", "run": token, "kv": {"gate": "stop"}},
            {"ts": 3, "type": "instrument", "run": token,
             "kv": {"counters": "dispatches_total"}},
        ]
        root2 = build_repo("bad", bad_events)
        ctx2 = make_ctx(repo_root=root2)
        m2 = build(ctx2, with_end_state=False)
        names = [x["name"] for x in m2["contradictions"]]
        if "blocks-without-dispatches" not in names:
            print("SELFTEST FAIL: expected blocks-without-dispatches, got %s" % names)
            ok = False

        # per-run scoping: a previous run's events must never be counted
        stale_events = [
            {"ts": 1, "type": "dispatch", "run": "M0@1600000000",
             "kv": {"agent": "developer"}},
            {"ts": 2, "type": "dispatch", "run": "M0@1600000000",
             "kv": {"agent": "developer"}},
        ]
        root3 = build_repo("stale", stale_events)
        ctx3 = make_ctx(repo_root=root3)
        m3 = build(ctx3, with_end_state=False)
        if m3["counters"]["dispatches_total"] is not None:
            print("SELFTEST FAIL: previous run's events leaked into this run "
                  "(dispatches_total=%r)" % m3["counters"]["dispatches_total"])
            ok = False
        if m3["notes"]["events_other_run"] != 2:
            print("SELFTEST FAIL: events_other_run=%r"
                  % m3["notes"]["events_other_run"])
            ok = False

        # metrics file from a different run must be rebuilt, not merged
        _write(os.path.join(root3, ".pipeline", "run-metrics.json"),
               json.dumps({"run": "M0@1600000000",
                           "counters": {"dispatches_total": 99}}))
        m4 = build(ctx3, with_end_state=False)
        write_metrics(ctx3, m4)
        again = json.loads(read_text(os.path.join(root3, ".pipeline",
                                                  "run-metrics.json")))
        if again["counters"]["dispatches_total"] == 99:
            print("SELFTEST FAIL: stale metrics file was merged, not rebuilt")
            ok = False

        # --trend / sidecars: empty dir -> explanatory message, not a crash
        root5 = build_repo("trend-empty", [])
        ctx5 = make_ctx(repo_root=root5)
        empty_trend = render_trend(ctx5, limit=5)
        if "no sidecars" not in empty_trend:
            print("SELFTEST FAIL: empty sidecar dir should explain itself, "
                  "got: %r" % empty_trend)
            ok = False

        # --trend / sidecars: write three sidecars via --out, then read
        # them back oldest-first, respecting --trend's limit
        for nnn, esc, red, work in (("001", 1, 0, 100), ("002", None, 2, 200),
                                     ("003", 3, 1, 300)):
            m5 = build(ctx5, with_end_state=False)
            m5["counters"]["escalation_requests"] = esc
            m5["counters"]["red_gate_blocks"] = red
            m5["counters"]["work_seconds"] = work
            m5["milestone"] = "M1"
            write_metrics(ctx5, m5,
                          out=os.path.join(sidecar_dir(ctx5), "%s-M1.json" % nnn))
        all_rows = load_sidecars(ctx5)
        if [r[1] for r in all_rows] != ["001-M1.json", "002-M1.json",
                                         "003-M1.json"]:
            print("SELFTEST FAIL: sidecars not read back oldest-first: %s"
                  % [r[1] for r in all_rows])
            ok = False
        limited = load_sidecars(ctx5, limit=2)
        if [r[1] for r in limited] != ["002-M1.json", "003-M1.json"]:
            print("SELFTEST FAIL: --trend limit kept the wrong rows: %s"
                  % [r[1] for r in limited])
            ok = False
        rendered = render_trend(ctx5, limit=2)
        if "002-M1.json" not in rendered or "001-M1.json" in rendered:
            print("SELFTEST FAIL: rendered trend did not respect the limit:\n%s"
                  % rendered)
            ok = False
        if "-" not in rendered:
            print("SELFTEST FAIL: a null counter (002's escalations) must "
                  "render as '-', not be dropped or shown as 0:\n%s" % rendered)
            ok = False
    except EnvError as exc:
        print("SELFTEST FAIL: environment error: %s" % exc)
        ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST %s: run_metrics.py" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="run_metrics.py",
        description="Roll the events log into run metrics; render the retro's "
                    "mechanical record. null = not instrumented, 0 = measured zero.",
        epilog="exit 0 = ok, 1 = contradiction (with --fail-on-contradiction), "
               "2 = usage, 3 = environment")
    ap.add_argument("--markdown", action="store_true",
                    help="emit the retro's section 2 instead of JSON")
    ap.add_argument("--json", action="store_true", help="print the metrics JSON")
    ap.add_argument("--measure-end-state", action="store_true",
                    help="add git-derived end state (commits, files, branch, HEAD)")
    ap.add_argument("--no-write", action="store_true",
                    help="do not write METRICS_JSON")
    ap.add_argument("--out", help="write METRICS_JSON somewhere else "
                    "(a retro points this at $DEV_DIR/metrics/NNN-<milestone>.json "
                    "to leave a permanent sidecar; see --trend)")
    ap.add_argument("--fail-on-contradiction", action="store_true",
                    help="exit 1 when a cross-counter contradiction is found")
    ap.add_argument("--list", action="store_true", help="list counter names")
    ap.add_argument("--trend", nargs="?", const=5, type=int, metavar="N",
                    help="print a last-N-runs table from $DEV_DIR/metrics/ "
                         "sidecars, oldest first (default N=5); reads only, "
                         "writes nothing")
    ap.add_argument("--repo-root")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.trend is not None:
        try:
            ctx = make_ctx(repo_root=args.repo_root)
        except EnvError as exc:
            sys.stderr.write("environment error: %s\n" % exc)
            return 3
        print(render_trend(ctx, limit=args.trend))
        return 0

    if args.list:
        for name, etype, filt, label in COUNTER_SPECS:
            print("%-24s <- %-20s %s" % (name, etype, label))
        for name, etype, key in MAP_SPECS:
            print("%-24s <- %-20s map by kv.%s" % (name, etype, key))
        print("%-24s <- %s" % ("work_seconds", "RUN_START/RUN_IDLE (read-only)"))
        print("%-24s <- %s" % ("wall_seconds", "RUN_START (read-only)"))
        print("%-24s <- %s" % ("findings_ledger_rows", "FINDINGS table"))
        print("%-24s <- %s" % ("checkpoint_files", "CHECKPOINTS_DIR"))
        return 0

    if args.selftest:
        return selftest()

    try:
        ctx = make_ctx(repo_root=args.repo_root)
        metrics = build(ctx, with_end_state=args.measure_end_state)
        if not args.no_write:
            write_metrics(ctx, metrics, args.out)
    except EnvError as exc:
        sys.stderr.write("environment error: %s\n" % exc)
        return 3

    if args.markdown:
        print(render_markdown(metrics))
    elif args.json:
        print(json.dumps(metrics, indent=2, sort_keys=True))
    else:
        print("metrics: run=%s milestone=%s events=%d contradictions=%d"
              % (metrics["run"], metrics["milestone"] or "-",
                 metrics["notes"]["events_this_run"],
                 len(metrics["contradictions"])))
        for x in metrics["contradictions"]:
            print("  contradiction %s: %s" % (x["name"], x["detail"]))
    if args.fail_on_contradiction and metrics["contradictions"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
