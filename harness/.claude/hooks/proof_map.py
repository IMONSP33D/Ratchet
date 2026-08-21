#!/usr/bin/env python3
# =============================================================================
# proof_map.py --- generate docs/evidence/M<n>/proof-map.md from the frozen
# contracts table (CONTRACT.md 7.2).
#
# WHY THIS EXISTS: the contract freezes the WIN -> *selector* mapping; the test
# names are DERIVED by running the stack pack's COLLECT_TESTS_CMD. There is no
# second, hand-maintained copy of the answer that can disagree with the suite.
#
# CONTRACT (this file is the writer AND the reader of the proof map):
#   input  : a markdown table with columns named `win` and `selector`
#            (columns are read BY NAME, never by position; extra columns such as
#            `name`, `requirements`, `evidence` are carried through when present)
#            default location: $PIPELINE_DIR/contracts.md, else
#            $PIPELINE_DIR/contracts-*.md merged in filename order
#   output : $EVIDENCE_DIR/M<n>/proof-map.md, whose first machine line is
#            <!-- ratchet:proof-map version=1 milestone=<M> head_sha=<sha>
#                 stack=<name> status=OK|SKIP|FAIL rows=<n> zero=<k>
#                 generated_at=<iso8601> -->
#            followed by a table: | win | name | selector | tests | status |
#            and one detail section per WIN row listing the collected test ids.
#   rule   : every WIN row must collect >= 1 test. A selector that collects zero
#            FAILS LOUDLY (exit 1) --- a proof map narrower than its own selector
#            is the defect class this generator deletes by construction.
#   stack  : the collector is ALWAYS the stack pack's COLLECT_TESTS_CMD. This
#            file never names a test runner. With the `generic.sh` pack (no
#            collector) the run SKIPs with a loud notice and writes a SKIP map.
#
# Stdlib only. utf-8 on every open. No project nouns.
#
# EXIT CODES
#   0  proof map written (status OK) or skipped cleanly (status SKIP);
#      in --verify mode: the on-disk map is current and complete
#   1  at least one WIN row collected zero tests, or --verify found the map
#      stale/incomplete/missing
#   2  usage error
#   3  environment error (config missing, contracts table missing, no `win`
#      or `selector` column, collector failed to execute)
# =============================================================================
"""Generate (or verify) the WIN-row proof map for one milestone."""

import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile

MACHINE_RE = re.compile(r"<!--\s*ratchet:proof-map\s+(.*?)-->", re.S)
MAP_VERSION = "1"

CONFIG_KEYS = [
    "REPO_ROOT", "PIPELINE_DIR", "EVIDENCE_DIR", "HOOKS_DIR", "RUN_ACTIVE",
    "STACK_NAME", "COLLECT_TESTS_CMD",
]


class EnvError(Exception):
    """Fail closed --- exit 3."""


_EXTRACT = (
    'set -u; cfg="$1"; shift; '
    '. "$cfg" >/dev/null 2>&1 || exit 9; '
    'for v in "$@"; do eval "val=\\${$v-}"; printf "%s\\t%s\\n" "$v" "$val"; done'
)

# Runs the stack pack's collector with $1 = selector. The command string is
# eval'd so a pack may define either a command line or a shell function.
_COLLECT = (
    'set -u; cfg="$1"; pack="$2"; sel="$3"; '
    '. "$cfg" >/dev/null 2>&1 || exit 9; '
    '[ -n "$pack" ] && [ -f "$pack" ] && { . "$pack" >/dev/null 2>&1 || exit 9; }; '
    '[ -n "${COLLECT_TESTS_CMD:-}" ] || exit 8; '
    'set -- "$sel"; eval "$COLLECT_TESTS_CMD"'
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
        raise EnvError("could not source %s: %s" % (cfg, proc.stderr.strip()))
    if proc.returncode != 0:
        raise EnvError("config extraction failed (%d)" % proc.returncode)
    values = {}
    for line in proc.stdout.replace("\r", "").split("\n"):
        if "\t" in line:
            k, v = line.split("\t", 1)
            values[k] = v
    return cfg, values


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

    def stack_pack(self):
        """Explicit pack file, when the core config did not already source it."""
        name = os.environ.get("RATCHET_STACK") or self.cfg.get("STACK_NAME", "")
        if not name:
            return ""
        hooks = self.path("HOOKS_DIR") or self.hooks_dir
        p = os.path.join(hooks, "stack", "%s.sh" % name)
        return p if os.path.isfile(p) else ""


def make_ctx(repo_root=None):
    hd = find_hooks_dir()
    root = repo_root or find_repo_root(hd)
    if repo_root:
        cand = os.path.join(repo_root, ".claude", "hooks")
        if os.path.isfile(os.path.join(cand, "ratchet.config.sh")):
            hd = cand
    cfg_path, cfg = load_config(hd, root, CONFIG_KEYS)
    cfg_root = cfg.get("REPO_ROOT", "").strip()
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


def head_sha(root):
    return git(root, "rev-parse", "HEAD") or "unknown"


# ---------------------------------------------------------------------------
# Contracts table --- columns read BY NAME
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


def parse_contract_rows(text, source):
    """Yield dicts keyed by lowercased column name, for every table that has
    both a `win` and a `selector` column."""
    rows = []
    header = None
    for line in text.split("\n"):
        cells = split_row(line)
        if cells is None:
            header = None
            continue
        low = [c.strip().lower() for c in cells]
        if header is None:
            if "win" in low and "selector" in low:
                header = low
            continue
        if is_separator_row(cells):
            continue
        row = {}
        for i, key in enumerate(header):
            row[key] = cells[i].strip() if i < len(cells) else ""
        row["__source__"] = source
        rows.append(row)
    return rows


def contract_sources(ctx, explicit):
    if explicit:
        missing = [p for p in explicit if not os.path.isfile(p)]
        if missing:
            raise EnvError("contracts file(s) not found: %s" % ", ".join(missing))
        return list(explicit)
    pdir = ctx.path("PIPELINE_DIR")
    if not pdir:
        raise EnvError("PIPELINE_DIR unset in ratchet.config.sh")
    single = os.path.join(pdir, "contracts.md")
    if os.path.isfile(single):
        return [single]
    slices = sorted(glob.glob(os.path.join(pdir, "contracts-*.md")))
    if slices:
        return slices
    raise EnvError("no contracts table found (looked for %s and %s)"
                   % (single, os.path.join(pdir, "contracts-*.md")))


def clean_cell(v):
    return (v or "").strip().strip("`").strip()


# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------
NOISE_RE = re.compile(
    r"^(=|-{3,}|\[|warning|WARNING|platform\s|rootdir|plugins:|configfile|"
    r"collected\s|no tests ran|cachedir|Test session|Determining|\s*$)")


def collect(ctx, selector, timeout=600):
    """Return (test_ids, status) where status is one of OK / ZERO / NOCMD.

    Raises EnvError when the collector exists but cannot be executed at all.
    """
    cmd = ctx.cfg.get("COLLECT_TESTS_CMD", "").strip()
    pack = ctx.stack_pack()
    if not cmd and not pack:
        return [], "NOCMD"
    proc = subprocess.run(
        ["bash", "-c", _COLLECT, "bash", ctx.cfg_path, pack, selector],
        cwd=ctx.root, capture_output=True, text=True, timeout=timeout,
        env=dict(os.environ, CLAUDE_PROJECT_DIR=ctx.root))
    if proc.returncode == 8:
        return [], "NOCMD"
    if proc.returncode == 9:
        raise EnvError("could not source config/stack pack for collection")
    ids = []
    for line in proc.stdout.replace("\r", "").split("\n"):
        s = line.strip()
        if not s or NOISE_RE.match(s):
            continue
        ids.append(s)
    if not ids:
        return [], "ZERO"
    return ids, "OK"


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def machine_line(fields):
    body = " ".join("%s=%s" % (k, v) for k, v in fields)
    return "<!-- ratchet:proof-map %s -->" % body


def parse_machine_line(text):
    m = MACHINE_RE.search(text or "")
    if not m:
        return {}
    out = {}
    for tok in m.group(1).split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def render(milestone, sha, stack, status, results, notice=""):
    now = utc_now_iso()
    zero = len([r for r in results if r["status"] != "OK"])
    lines = []
    lines.append("# Proof map --- %s" % milestone)
    lines.append("")
    lines.append("Generated by `.claude/hooks/proof_map.py`. **Do not hand-edit** ---")
    lines.append("regenerate with `proof_map.py --milestone %s`. The WIN -> selector"
                 % milestone)
    lines.append("mapping is frozen in the contracts table; the test ids below are")
    lines.append("derived by the stack pack's collector, so there is no second copy")
    lines.append("of the answer that can disagree with the suite.")
    lines.append("")
    lines.append(machine_line([
        ("version", MAP_VERSION), ("milestone", milestone), ("head_sha", sha),
        ("stack", stack or "unknown"), ("status", status),
        ("rows", str(len(results))), ("zero", str(zero)),
        ("generated_at", now)]))
    lines.append("")
    if notice:
        lines.append("> **NOTICE.** %s" % notice)
        lines.append("")
    lines.append("| win | name | selector | tests | status |")
    lines.append("|---|---|---|---|---|")
    for r in results:
        lines.append("| %s | %s | `%s` | %d | %s |"
                     % (r["win"], r["name"] or "-", r["selector"],
                        len(r["tests"]), r["status"]))
    lines.append("")
    for r in results:
        lines.append("## %s --- %s" % (r["win"], r["name"] or "(unnamed)"))
        lines.append("")
        lines.append("selector: `%s`" % r["selector"])
        if r.get("requirements"):
            lines.append("")
            lines.append("requirements: %s" % r["requirements"])
        lines.append("")
        if r["status"] == "OK":
            shown = r["tests"][:200]
            for t in shown:
                lines.append("- `%s`" % t)
            if len(r["tests"]) > len(shown):
                lines.append("- ... and %d more" % (len(r["tests"]) - len(shown)))
        elif r["status"] == "ZERO":
            lines.append("- **COLLECTED ZERO TESTS.** This WIN row cannot be")
            lines.append("  evidenced by the suite as written. Fix the selector or")
            lines.append("  write the test --- this is a setup defect, not a")
            lines.append("  judgement call.")
        else:
            lines.append("- collection SKIPPED (no collector in this stack pack)")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------
def milestone_from_run(ctx):
    p = ctx.path("RUN_ACTIVE")
    if p and os.path.isfile(p):
        v = read_text(p).strip().split("\n")[0].strip()
        if v:
            return v
    return ""


def normalise_milestone(m):
    m = (m or "").strip()
    if not m:
        return ""
    if re.match(r"^[Mm]\d+$", m):
        return "M" + m[1:]
    mm = re.search(r"M(\d+)", m)
    return "M%s" % mm.group(1) if mm else m


def out_path(ctx, milestone):
    ev = ctx.path("EVIDENCE_DIR")
    if not ev:
        raise EnvError("EVIDENCE_DIR unset in ratchet.config.sh")
    return os.path.join(ev, milestone, "proof-map.md")


def generate(ctx, milestone, contracts, write=True, timeout=600):
    rows = []
    for src in contract_sources(ctx, contracts):
        rows.extend(parse_contract_rows(read_text(src), src))
    if not rows:
        raise EnvError("contracts table has no rows with `win` and `selector` "
                       "columns (columns are matched by name)")
    prefix = "WIN-%s-" % milestone
    mine = [r for r in rows if clean_cell(r.get("win")).startswith(prefix)]
    if not mine:
        raise EnvError("no WIN rows for milestone %s in the contracts table "
                       "(looked for ids starting %s)" % (milestone, prefix))
    results = []
    skipped = False
    for r in mine:
        sel = clean_cell(r.get("selector"))
        entry = {"win": clean_cell(r.get("win")),
                 "name": clean_cell(r.get("name")),
                 "requirements": clean_cell(r.get("requirements")
                                            or r.get("requirement ids")),
                 "selector": sel, "tests": [], "status": "ZERO"}
        if not sel:
            entry["status"] = "ZERO"
            results.append(entry)
            continue
        ids, status = collect(ctx, sel, timeout=timeout)
        entry["tests"] = ids
        entry["status"] = {"OK": "OK", "ZERO": "ZERO", "NOCMD": "SKIP"}[status]
        if status == "NOCMD":
            skipped = True
        results.append(entry)

    zero = [r for r in results if r["status"] == "ZERO"]
    if skipped:
        status = "SKIP"
        notice = ("The active stack pack defines no COLLECT_TESTS_CMD "
                  "(generic pack). Test collection was SKIPPED; this map proves "
                  "nothing about the suite and must not be cited as WIN evidence.")
    elif zero:
        status = "FAIL"
        notice = ("%d WIN row(s) collected ZERO tests. A selector that collects "
                  "nothing cannot evidence its win condition." % len(zero))
    else:
        status = "OK"
        notice = ""

    text = render(milestone, head_sha(ctx.root),
                  ctx.cfg.get("STACK_NAME", ""), status, results, notice)
    dest = out_path(ctx, milestone)
    if write:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(text)
    return {"path": dest, "text": text, "status": status,
            "results": results, "zero": [r["win"] for r in zero]}


def verify(ctx, milestone):
    """Read-only: is the on-disk map current and complete? (no collector run)"""
    dest = out_path(ctx, milestone)
    problems = []
    if not os.path.isfile(dest):
        return {"ok": False, "path": dest, "status": "MISSING",
                "problems": ["proof map not generated: %s" % dest]}
    text = read_text(dest)
    meta = parse_machine_line(text)
    if not meta:
        return {"ok": False, "path": dest, "status": "UNPARSEABLE",
                "problems": ["no ratchet:proof-map machine line in %s" % dest]}
    sha = head_sha(ctx.root)
    if meta.get("head_sha") != sha:
        problems.append("proof map generated at %s but HEAD is %s --- regenerate"
                        % (meta.get("head_sha", "?")[:12], sha[:12]))
    if meta.get("milestone") != milestone:
        problems.append("proof map is for %s, not %s"
                        % (meta.get("milestone"), milestone))
    status = meta.get("status", "?")
    if status == "FAIL":
        problems.append("proof map records %s WIN row(s) collecting zero tests"
                        % meta.get("zero", "?"))
    elif status == "SKIP":
        problems.append("proof map was generated with no collector (stack=%s); "
                        "WIN rows are unproven" % meta.get("stack", "?"))
    # every row in the table must collect >= 1 test
    header = None
    for line in text.split("\n"):
        cells = split_row(line)
        if cells is None:
            continue
        low = [c.lower() for c in cells]
        if header is None:
            if "win" in low and "tests" in low:
                header = low
            continue
        if is_separator_row(cells):
            continue
        try:
            win = cells[low_index(header, "win")]
            n = int(cells[low_index(header, "tests")] or "0")
        except (ValueError, IndexError):
            continue
        if n < 1:
            problems.append("%s collects %d tests" % (win, n))
    return {"ok": not problems, "path": dest, "status": status,
            "problems": problems, "meta": meta}


def low_index(header, key):
    return header.index(key)


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------
FIXTURE_CONFIG = """#!/usr/bin/env bash
# Selftest fixture config (not the shipped defaults).
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
PIPELINE_DIR=".pipeline"
EVIDENCE_DIR="docs/evidence"
HOOKS_DIR=".claude/hooks"
RUN_ACTIVE=".pipeline/run-active"
STACK_NAME="fixture"
COLLECT_TESTS_CMD='case "$1" in
  good*) printf "tests/test_a.py::test_one\\ntests/test_a.py::test_two\\n" ;;
  *) printf "collected 0 items\\n" ;;
esac'
"""

GENERIC_CONFIG = """#!/usr/bin/env bash
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
PIPELINE_DIR=".pipeline"
EVIDENCE_DIR="docs/evidence"
HOOKS_DIR=".claude/hooks"
RUN_ACTIVE=".pipeline/run-active"
STACK_NAME="generic"
COLLECT_TESTS_CMD=""
"""

CONTRACTS_OK = """# Contracts

| win | name | requirements | selector |
|---|---|---|---|
| WIN-M1-01 | gate-artifact-matches-head | REQ-1 | good-selector-one |
| WIN-M1-02 | ledger-row-count-holds | REQ-2 | good-selector-two |
"""

CONTRACTS_BAD = CONTRACTS_OK + "| WIN-M1-03 | orphan-win-row | REQ-3 | nothing-here |\n"


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def selftest():
    ok = True
    tmp = tempfile.mkdtemp(prefix="ratchet-proofmap-")
    try:
        def build(name, cfg, contracts):
            root = os.path.join(tmp, name)
            _write(os.path.join(root, ".claude", "hooks", "ratchet.config.sh"), cfg)
            _write(os.path.join(root, ".pipeline", "contracts.md"), contracts)
            _write(os.path.join(root, ".pipeline", "run-active"), "M1\n")
            return root

        # PASS: every selector collects tests
        root = build("pass", FIXTURE_CONFIG, CONTRACTS_OK)
        ctx = make_ctx(repo_root=root)
        res = generate(ctx, "M1", None)
        if res["status"] != "OK" or res["zero"]:
            print("SELFTEST FAIL: expected OK map, got %s %s"
                  % (res["status"], res["zero"]))
            ok = False
        if not os.path.isfile(res["path"]):
            print("SELFTEST FAIL: map not written")
            ok = False
        v = verify(ctx, "M1")
        if not v["ok"]:
            print("SELFTEST FAIL: fresh map failed verify: %s" % v["problems"])
            ok = False

        # FAIL: one selector collects zero tests
        root2 = build("fail", FIXTURE_CONFIG, CONTRACTS_BAD)
        ctx2 = make_ctx(repo_root=root2)
        res2 = generate(ctx2, "M1", None)
        if res2["status"] != "FAIL" or res2["zero"] != ["WIN-M1-03"]:
            print("SELFTEST FAIL: expected zero-collection FAIL, got %s %s"
                  % (res2["status"], res2["zero"]))
            ok = False
        v2 = verify(ctx2, "M1")
        if v2["ok"]:
            print("SELFTEST FAIL: verify accepted a map with a zero-collecting row")
            ok = False

        # SKIP: generic stack pack, no collector --- must not crash
        root3 = build("skip", GENERIC_CONFIG, CONTRACTS_OK)
        ctx3 = make_ctx(repo_root=root3)
        res3 = generate(ctx3, "M1", None)
        if res3["status"] != "SKIP":
            print("SELFTEST FAIL: generic pack should SKIP, got %s" % res3["status"])
            ok = False

        # stale map: verify must reject when head_sha does not match HEAD
        stale = read_text(res["path"]).replace(
            "head_sha=%s" % (parse_machine_line(read_text(res["path"]))
                             .get("head_sha")), "head_sha=deadbeefdeadbeef")
        _write(res["path"], stale)
        v3 = verify(ctx, "M1")
        if v3["ok"]:
            print("SELFTEST FAIL: verify accepted a stale map")
            ok = False
    except EnvError as exc:
        print("SELFTEST FAIL: environment error: %s" % exc)
        ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST %s: proof_map.py" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="proof_map.py",
        description="Generate docs/evidence/M<n>/proof-map.md from the frozen "
                    "contracts table using the stack pack's collector.",
        epilog="exit 0 = written/skipped-clean, 1 = a WIN row collects zero tests "
               "or the map is stale, 2 = usage, 3 = environment")
    ap.add_argument("--milestone", help="milestone id, e.g. M1 (default: RUN_ACTIVE)")
    ap.add_argument("--contracts", action="append",
                    help="contracts table path (repeatable; default: derived)")
    ap.add_argument("--repo-root")
    ap.add_argument("--verify", action="store_true",
                    help="read-only: is the on-disk map current and complete?")
    ap.add_argument("--stdout", action="store_true",
                    help="print the map instead of writing it")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--timeout", type=int, default=600,
                    help="seconds allowed per collector invocation")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    try:
        ctx = make_ctx(repo_root=args.repo_root)
        milestone = normalise_milestone(args.milestone or milestone_from_run(ctx))
        if not milestone:
            sys.stderr.write("no milestone given and RUN_ACTIVE is empty; "
                             "pass --milestone M<n>\n")
            return 2
        if args.verify:
            v = verify(ctx, milestone)
            if args.json:
                print(json.dumps(v, indent=2))
            else:
                print("proof map %s: %s" % (v["path"],
                                            "current" if v["ok"] else "STALE/INCOMPLETE"))
                for p in v["problems"]:
                    print("  - %s" % p)
            return 0 if v["ok"] else 1

        res = generate(ctx, milestone, args.contracts,
                       write=not args.stdout, timeout=args.timeout)
        if args.stdout:
            sys.stdout.write(res["text"])
        if args.json:
            print(json.dumps({"path": res["path"], "status": res["status"],
                              "zero": res["zero"],
                              "rows": [{"win": r["win"], "selector": r["selector"],
                                        "tests": len(r["tests"]),
                                        "status": r["status"]}
                                       for r in res["results"]]}, indent=2))
        elif not args.stdout:
            print("proof map: %s (status %s, %d rows)"
                  % (res["path"], res["status"], len(res["results"])))
            for r in res["results"]:
                print("  %-14s %-8s %s" % (r["win"], r["status"], r["selector"]))
        if res["status"] == "FAIL":
            sys.stderr.write(
                "FAIL: %s collected zero tests. A WIN row that collects nothing "
                "cannot be evidenced; fix the selector or write the test.\n"
                % ", ".join(res["zero"]))
            return 1
        if res["status"] == "SKIP":
            sys.stderr.write(
                "NOTICE: stack pack %r defines no COLLECT_TESTS_CMD --- test "
                "collection SKIPPED. This map is not WIN evidence.\n"
                % ctx.cfg.get("STACK_NAME", ""))
        return 0
    except EnvError as exc:
        sys.stderr.write("environment error: %s\n" % exc)
        return 3
    except subprocess.TimeoutExpired:
        sys.stderr.write("environment error: collector timed out\n")
        return 3


if __name__ == "__main__":
    sys.exit(main())
