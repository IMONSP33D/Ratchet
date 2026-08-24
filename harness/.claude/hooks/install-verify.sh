#!/usr/bin/env bash
# =============================================================================
# install-verify.sh - did the install land, and does THIS machine run it?
#
# This is NOT Ratchet's test suite. That suite (test_hooks.py, 193 tests) proves
# the harness LOGIC is correct and belongs in CI on the Ratchet repo, where it
# runs once per change. Running it on every user's machine at install time meant
# every install re-litigated Ratchet's own logic on someone else's hardware:
# 265 bash spawns, ~30s on Linux and ~6 minutes under Git-Bash.
#
# There are only two questions an install actually has to answer:
#
#   A. DEPLOYMENT - did the files land correctly? This is pure inspection. No
#      subprocesses. Files present and non-empty, no {{MARKER}} left behind,
#      settings.json parses and has its hooks wired, the ignore/attribute/key
#      protections are real.
#
#   B. HOST - does this machine's shell and filesystem make the gates behave?
#      This is the part inspection CANNOT answer, and the part that actually
#      broke on Windows. About a dozen probes, not 265.
#
# Exit: 0 = verified · 1 = verified with warnings · 2 = FAILED, do not ship on it
#
# Standalone:  .claude/hooks/install-verify.sh [--target <dir>] [--quiet]
# =============================================================================
set -uo pipefail

TARGET="${CLAUDE_PROJECT_DIR:-}"
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) shift; TARGET="${1:-}" ;;
    --target=*) TARGET="${1#--target=}" ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  shift
done
if [ -z "$TARGET" ]; then
  TARGET="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
fi
[ -d "$TARGET/.claude/hooks" ] || { printf 'install-verify: no Ratchet install at %s\n' "$TARGET" >&2; exit 2; }
cd "$TARGET" || exit 2

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_Y=$'\033[33m'; C_G=$'\033[32m'; C_0=$'\033[0m'
else C_R=""; C_Y=""; C_G=""; C_0=""; fi

FAIL=0; WARN=0
ok()   { [ "$QUIET" = "1" ] || printf '  %sok%s   %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$*" >&2; WARN=$((WARN+1)); }
head1(){ [ "$QUIET" = "1" ] || printf '\n%s\n' "$*"; }

# =============================================================================
# A. DEPLOYMENT - inspection only, no subprocesses
# =============================================================================
head1 "A. Deployment"

# A1. Every deployed file exists and is non-empty. An empty hook is a gate that
#     silently allows everything, which is the worst possible failure mode.
n=0; empty=0
for f in .claude/hooks/*.sh .claude/hooks/*.py .claude/hooks/stack/*.sh \
         .claude/agents/*.md .claude/doctrine/*.md; do
  [ -e "$f" ] || continue
  n=$((n+1))
  [ -s "$f" ] || { bad "$f is EMPTY - a zero-byte gate allows everything"; empty=$((empty+1)); }
done
[ "$n" -ge 30 ] || bad "only $n harness files deployed; expected 30+. The copy did not finish."
[ "$empty" = "0" ] && [ "$n" -ge 30 ] && ok "$n harness files present, none empty"

# A2. The five gates that MUST exist by name. A missing one is not a degraded
#     harness, it is a wall that is simply not there.
for f in guard.sh scope-guard.sh stop-gate.sh hooklib.sh ratchet.config.sh; do
  [ -s ".claude/hooks/$f" ] || bad "missing control-layer file: .claude/hooks/$f"
done

# A3. No unsubstituted {{MARKER}}. A surviving marker inside an agent definition
#     becomes literal text in a system prompt: the model reads "{{VERIFY_CMD}}"
#     as a string instead of your test command.
# {{MARKER}} / {{MARKERS}} are excluded: the doctrine uses those literally, in
# prose, to explain what a marker IS. They are never substitution keys.
LEFT=""
for f in $(grep -rlE '\{\{[A-Z0-9_]{2,}\}\}' .claude/agents .claude/doctrine .claude/settings.json 2>/dev/null); do
  if grep -oE '\{\{[A-Z0-9_]{2,}\}\}' "$f" \
     | grep -vxF -e '{{MARKER}}' -e '{{MARKERS}}' | grep -q .; then
    LEFT="$LEFT$f"$'\n'
  fi
done
if [ -n "$LEFT" ]; then
  bad "unsubstituted {{MARKERS}} remain in:"
  printf '%s\n' "$LEFT" | sed 's/^/         /' >&2
  printf '         Fix: ./install.sh --target . --substitute-only\n' >&2
else
  ok "no unsubstituted {{MARKERS}}"
fi

# A4. settings.json parses and wires the hooks. This file IS the permission
#     surface; malformed, Claude Code ignores it and every gate is bypassed.
if [ ! -s .claude/settings.json ]; then
  bad ".claude/settings.json is missing - no hooks are wired, no gate runs"
elif command -v jq >/dev/null 2>&1; then
  if ! jq -e . .claude/settings.json >/dev/null 2>&1; then
    bad ".claude/settings.json is not valid JSON - Claude Code will ignore it entirely"
  else
    HK=$(jq -r '[.hooks[]?[]?.hooks[]?.command] | length' .claude/settings.json 2>/dev/null)
    [ "${HK:-0}" -ge 6 ] && ok "settings.json valid, $HK hooks wired" \
                         || bad "settings.json wires only ${HK:-0} hooks; expected 8"
    jq -e '.permissions.deny | length > 0' .claude/settings.json >/dev/null 2>&1 \
      && ok "permission deny list present" \
      || bad "settings.json has an EMPTY deny list - nothing is walled"
  fi
else
  warn "jq absent; settings.json not parsed (install.sh requires jq, so this is unusual)"
fi

# A5. Protections that are easy to write and easy to silently not have.
if [ -f .gitignore ] && grep -qxF 'secrets/' .gitignore 2>/dev/null; then
  ok "secrets/ is gitignored"
else
  bad "secrets/ is NOT in .gitignore - the signing key can be committed"
fi
if [ -f .gitattributes ] && grep -q 'hooks/\*\* text eol=lf' .gitattributes 2>/dev/null; then
  ok ".claude/hooks pinned to LF"
else
  warn ".gitattributes does not pin hooks to LF; a collaborator cloning with"
  printf '         core.autocrlf=true gets CRLF hooks and every gate dies on its shebang\n' >&2
fi
if [ -f secrets/escalation.key ]; then
  P="$(ls -l secrets/escalation.key 2>/dev/null | cut -c1-10)"
  case "$P" in -rw-------*) ok "escalation key is 0600" ;;
                *) warn "escalation key permissions are $P (want 0600)" ;; esac
fi

# =============================================================================
# B. HOST - the part inspection cannot answer
# =============================================================================
head1 "B. This machine"

# B1. bash runs a command. On Windows the first bash on PATH is often the WSL
#     relay, which dies before any hook body executes.
if bash -c 'printf ok' >/dev/null 2>&1; then ok "bash runs commands"
else bad "the resolved bash cannot run a command - no hook can execute"; fi

# B2. A real Python 3. The Windows Store stub answers to python3, exits
#     non-zero and prints nothing.
PY=""
for c in "${RATCHET_PYTHON:-}" python3 python "py -3"; do
  [ -n "$c" ] || continue
  [ "$($c -c 'import sys;print(sys.version_info[0])' 2>/dev/null)" = "3" ] && { PY="$c"; break; }
done
[ -n "$PY" ] && ok "python 3 available ($PY)" \
             || bad "no working python 3 - check_done.py cannot evaluate the ship gate"

# B3. jq, which every security decision parses JSON with.
command -v jq >/dev/null 2>&1 && ok "jq available" \
                              || bad "jq missing - the guards block rather than guess at JSON"

# B4. git, and this is a work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && ok "git work tree" \
  || bad "not a git work tree - the scope check cannot enumerate changed files"

# B5. THE PATH DIALECT CHECK. Six spellings of one directory; if this host's
#     spelling does not reduce, every gate compares two forms of the same path
#     and disagrees with itself. This is what silently broke on Git-Bash.
PROBE="$(bash -c '
  . .claude/hooks/ratchet.config.sh >/dev/null 2>&1 || exit 9
  . .claude/hooks/hooklib.sh        >/dev/null 2>&1 || exit 9
  rt_repo_rel_var "$REPO_ROOT/.pipeline/probe.md"; printf "%s|%s|%s" "$RT_REL" "$(rt_platform)" "${RT_WINPATH:-?}"
' 2>/dev/null)"
REL="${PROBE%%|*}"; REST="${PROBE#*|}"; PLAT="${REST%%|*}"; WINP="${REST##*|}"
if [ "$REL" = ".pipeline/probe.md" ]; then
  ok "paths reduce correctly (platform: ${PLAT:-?})"
else
  bad "a repo path did NOT reduce: got '${REL:-<nothing>}', wanted '.pipeline/probe.md'"
  printf '         Every gate compares paths. Unreduced, .pipeline/ stops matching its own\n' >&2
  printf '         exemption and .context/ stops matching the governing corpus.\n' >&2
fi

# B6. Does the harness AGREE WITH THE FILESYSTEM about case? Probe the volume
#     empirically, then compare. Wrong here means the control-set wall is either
#     bypassable by changing a letter's case, or fires on innocent POSIX files.
mkdir -p .pipeline >/dev/null 2>&1
: > .pipeline/.rt-case-probe 2>/dev/null
if [ -e .pipeline/.RT-CASE-PROBE ]; then FS_CI=1; else FS_CI=0; fi
rm -f .pipeline/.rt-case-probe 2>/dev/null
if [ "$WINP" = "$FS_CI" ]; then
  ok "case-sensitivity detected correctly (filesystem is $([ "$FS_CI" = 1 ] && echo insensitive || echo sensitive))"
else
  bad "case mismatch: filesystem is $([ "$FS_CI" = 1 ] && echo INsensitive || echo sensitive), harness thinks RT_WINPATH=$WINP"
  printf '         If the volume ignores case and the harness does not, then Guard.sh does not\n' >&2
  printf '         match the control-set entry guard.sh and the wall is one shift key wide.\n' >&2
fi

# B7. Do the gates actually fire on this host? One allow and one block per
#     guard. A gate that cannot block is decoration; a gate that blocks
#     everything has stopped the run rather than the risk.
gfire() { printf '%s' "$2" | bash .claude/hooks/"$1" >/dev/null 2>&1; printf '%s' "$?"; }
A=$(gfire guard.sh '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')
B=$(gfire guard.sh '{"tool_name":"Bash","tool_input":{"command":"cat secrets/escalation.key"}}')
[ "$A" = "0" ] && [ "$B" = "2" ] && ok "guard.sh: allows ordinary commands, blocks secrets" \
  || bad "guard.sh misbehaves (ls exited $A want 0; secret read exited $B want 2)"
C=$(gfire scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":".pipeline/notes.md","content":"x"}}')
D=$(gfire scope-guard.sh '{"tool_name":"Write","tool_input":{"file_path":".claude/hooks/guard.sh","content":"x"}}')
[ "$C" = "0" ] && [ "$D" = "2" ] && ok "scope-guard.sh: allows scratch, blocks the control layer" \
  || bad "scope-guard.sh misbehaves (scratch exited $C want 0; control-set exited $D want 2)"

# =============================================================================
head1 "Result"
if [ "$FAIL" -gt 0 ]; then
  printf '  %s%d check(s) FAILED%s, %d warning(s).\n' "$C_R" "$FAIL" "$C_0" "$WARN" >&2
  printf '  Do not start a milestone on this. A gate you cannot reason about is not a gate.\n' >&2
  exit 2
fi
[ "$QUIET" = "1" ] || printf '  %sverified%s - deployment complete, gates confirmed working on this machine (%d warnings)\n' "$C_G" "$C_0" "$WARN"
[ "$WARN" -gt 0 ] && exit 1
exit 0
