#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/subagent-gate.sh
#
# Contract ............ CONTRACT.md §3 (SubagentStop / matcher `developer`),
#                       §5.4 (attribution: exact | sound | weak),
#                       law 1 backstop: a developer does not touch tests
# Event ............... SubagentStop, matcher: developer
# Blocking mechanism .. stdout JSON {"decision":"block","reason":"..."} exit 0.
#                       BLOCK means the subagent keeps working.
# Fail-closed ......... control layer unloadable => BLOCK once (the
#                       stop_hook_active guard prevents a loop).
#                       No run active => inert, allow (§5.1).
#
# WHAT THIS GATE ASSERTS
#   1. The fast scoped suite for this partition is GREEN.
#   2. No test file and no test-surface file was touched by this agent.
#      Law 1 says the test-writer authors red and the developer makes it
#      green; a developer editing a test is the one move that can make the
#      whole pipeline lie about itself. This is the mechanical backstop.
#
# ATTRIBUTION DISCIPLINE (§5.4) - READ BEFORE CHANGING THE WORDING
#   Modes are named and the gate prints which one it used:
#     exact  - a dispatch baseline snapshot exists for this dispatch id
#     sound  - a partition glob is on disk for this dispatch (scope-guard
#              refused every write outside it, so a path outside it is
#              provably not this agent's)
#     weak   - forbidden-path filter only; the gate says out loud that it is
#              weak
#   IN ANY MODE BELOW `exact` THIS GATE REPORTS AND NEVER ORDERS A REVERT.
#   The measured failure: gates that diffed the whole working tree handed an
#   arriving agent every pre-existing change as its own and ordered a revert -
#   seven times those were human-owned files the agent may not touch, so the
#   gate's own remediation instruction was a contract violation. A revert is
#   never ordered for a governing-corpus or control-layer path in ANY mode.
#
# STATE FILE OWNED BY THIS SCRIPT (§0.7)
# ---------------------------------------------------------------------------
# $PIPELINE_DIR/state/subagent-retries.<sid>.<dispatch>
#     One line, decimal integer: how many times this gate has BLOCKED for this
#     session + dispatch pair. <dispatch> is "nodispatch" when no dispatch id
#     is known. Cleared by session-start.sh and gc-prune.sh (start|archive|
#     prune).
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
TAIL_LINES="${SUBAGENT_TAIL_LINES:-40}"

RT_RAW=""
_read_payload_raw() {
  if [ ! -t 0 ]; then RT_RAW="$(cat 2>/dev/null || true)"; fi
  RT_RAW="${RT_RAW//$'\r'/}"
}
_stop_hook_active_raw() {
  case "$RT_RAW" in *'"stop_hook_active"'*'true'*) return 0 ;; esac
  return 1
}
_json_str() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -Rs . 2>/dev/null && return 0
  fi
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' 2>/dev/null)"
  printf '"%s"' "$s"
}
_emit_block() {
  if command -v rt_block_json >/dev/null 2>&1; then rt_block_json "$1"; exit 0; fi
  printf '{"decision":"block","reason":%s}\n' "$(_json_str "$1")"
  exit 0
}
_allow() { exit 0; }

_bootstrap() {
  [ -r "$RT_SELF_DIR/ratchet.config.sh" ] || return 1
  # shellcheck disable=SC1090,SC1091
  . "$RT_SELF_DIR/ratchet.config.sh" || return 1
  local lib=""
  if [ -n "${HOOKS_DIR:-}" ] && [ -r "${HOOKS_DIR}/hooklib.sh" ]; then
    lib="${HOOKS_DIR}/hooklib.sh"
  elif [ -r "$RT_SELF_DIR/hooklib.sh" ]; then
    lib="$RT_SELF_DIR/hooklib.sh"
  else
    return 1
  fi
  # shellcheck disable=SC1090,SC1091
  . "$lib" || return 1
  command -v rt_repo_root >/dev/null 2>&1 && { rt_repo_root >/dev/null 2>&1 || true; }
  return 0
}

_abs() {
  case "$1" in
    /*|[A-Za-z]:[\\/]*) printf '%s' "$1" ;;
    *) printf '%s/%s' "${REPO_ROOT:-$PWD}" "$1" ;;
  esac
}
_now() { date -u +%s 2>/dev/null || echo 0; }
_read_first_line() {
  local f="$1" line=""
  [ -r "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || true
  printf '%s' "${line//$'\r'/}"
}
_field() {
  local f="$1" v=""
  if command -v rt_json_field >/dev/null 2>&1; then v="$(rt_json_field "$f" 2>/dev/null)"; fi
  if [ -z "$v" ] && command -v jq >/dev/null 2>&1 && [ -n "$RT_RAW" ]; then
    v="$(printf '%s' "$RT_RAW" | jq -r --arg p "$f" \
      'try getpath($p|split(".")) catch empty | select(.!=null) | tostring' 2>/dev/null)"
  fi
  if [ -z "$v" ] && [ -n "$RT_RAW" ]; then
    local leaf="${f##*.}"
    v="$(printf '%s' "$RT_RAW" | sed -n "s/.*\"${leaf}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"
  fi
  printf '%s' "$v"
}
_sid() {
  local s; s="$(_field session_id)"
  s="$(printf '%s' "$s" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_' 2>/dev/null)"
  [ -n "$s" ] || s="nosession"
  printf '%s' "${s:0:40}"
}
_event() {
  local t="$1"; shift
  if command -v rt_event >/dev/null 2>&1; then rt_event "$t" "$@" >/dev/null 2>&1 || true
  elif [ -r "$RT_SELF_DIR/pipeline-event.sh" ]; then
    bash "$RT_SELF_DIR/pipeline-event.sh" "$t" "$@" >/dev/null 2>&1 || true
  fi
  return 0
}
_state_dir() {
  local d; d="$(_abs "${PIPELINE_DIR:-.pipeline}")/state"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}
_run_capped() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" bash -c "$*" 2>&1
  else bash -c "$*" 2>&1; fi
}

# --- dispatch identity (§5.4 env-var caveat: the FILES are authoritative) --- #
_dispatch_dir() { printf '%s' "$(_abs "${DISPATCH_DIR:-${PIPELINE_DIR:-.pipeline}/dispatch}")"; }
_dispatch_id() {
  local d id=""
  if command -v rt_dispatch_id >/dev/null 2>&1; then
    id="$(rt_dispatch_id 2>/dev/null)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  fi
  d="$(_dispatch_dir)"
  id="$(_read_first_line "$d/current" 2>/dev/null)"
  [ -n "$id" ] || id="${PIPELINE_DISPATCH_ID:-}"
  printf '%s' "$id"
}
# exact > sound > weak, decided from what is on disk.
# The mode NAME comes from hooklib when it is available - one answer, not two.
# The disk fallback exists only for a hooklib-less run.
_attribution_mode() {
  local id="$1" d m
  if command -v rt_attributable >/dev/null 2>&1; then
    m="$(rt_attributable "." 2>/dev/null)"
    case "$m" in exact|sound|weak) printf '%s' "$m"; return 0 ;; esac
  fi
  d="$(_dispatch_dir)"
  if [ -n "$id" ] && [ -r "$d/$id.baseline" ]; then printf 'exact'; return 0; fi
  if [ -n "$id" ] && [ -r "$d/$id.glob" ]; then printf 'sound'; return 0; fi
  if [ -n "${PIPELINE_PARTITION_GLOB:-}" ]; then printf 'sound'; return 0; fi
  printf 'weak'
}
_globs_for() {
  local id="$1" d
  d="$(_dispatch_dir)"
  if command -v rt_dispatch_glob >/dev/null 2>&1; then
    rt_dispatch_glob "$id" 2>/dev/null | grep -v '^[[:space:]]*$' && return 0
  fi
  if [ -n "$id" ] && [ -r "$d/$id.glob" ]; then
    sed 's/\r$//' "$d/$id.glob" 2>/dev/null | grep -v '^[[:space:]]*$'
    return 0
  fi
  [ -n "${PIPELINE_PARTITION_GLOB:-}" ] && printf '%s\n' "${PIPELINE_PARTITION_GLOB}"
  return 0
}

# Exact mode needs a DERIVED baseline (a plain path list) on disk, and only
# `dispatch-baseline.sh changed` can produce one - the snapshot alone is a
# pre-dispatch record. Refresh it here so hooklib's rt_attributable and this
# gate are reading the same answer, computed now rather than at dispatch time.
_refresh_exact_baseline() { # <id>
  local d
  [ -n "${1:-}" ] || return 0
  d="$(_dispatch_dir)"
  [ -r "$d/$1.snapshot" ] || return 0
  [ -r "$RT_SELF_DIR/dispatch-baseline.sh" ] || return 0
  bash "$RT_SELF_DIR/dispatch-baseline.sh" changed "$1" >/dev/null 2>&1 || true
  return 0
}

_changed_files() {
  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  {
    git diff --name-only 2>/dev/null
    git diff --name-only --cached 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
    local base="${BASE_BRANCH:-main}" mb=""
    if git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      mb="$(git merge-base "$base" HEAD 2>/dev/null)"
      [ -n "$mb" ] && git diff --name-only "$mb" HEAD 2>/dev/null
    fi
  } | sed 's/\r$//' | sed 's#^\./##' | grep -v '^[[:space:]]*$' | sort -u
}

# Is <path> this agent's work? rt_attributable when hooklib provides it, else
# the local fallback: baseline-aware in exact mode, glob-aware in sound mode,
# everything in weak mode.
# rt_attributable (hooklib) prints the MODE on stdout and encodes the answer in
# its exit code: 0 = may be this dispatch's work, 1 = provably NOT this
# dispatch's, 2 = undecidable (weak mode). Only exit 1 removes a path from the
# report. Treating 2 as "not ours" would turn "we cannot tell" into "all
# clear", which is the exact inversion this gate exists to prevent.
_is_ours() { # <path> <id> <mode>
  local p="$1" id="$2" mode="$3" globs rc
  if command -v rt_attributable >/dev/null 2>&1; then
    rt_attributable "$p" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] && return 1
    return 0
  fi
  case "$mode" in
    exact)
      if [ -r "$RT_SELF_DIR/dispatch-baseline.sh" ]; then
        bash "$RT_SELF_DIR/dispatch-baseline.sh" changed "$id" 2>/dev/null \
          | grep -Fxq -- "$p" && return 0
        return 1
      fi
      return 0 ;;
    sound)
      globs="$(_globs_for "$id")"
      [ -n "$globs" ] || return 0
      if command -v rt_glob_match >/dev/null 2>&1; then
        rt_glob_match "$p" "$globs" >/dev/null 2>&1 && return 0
        return 1
      fi
      local g
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        # shellcheck disable=SC2254
        case "$p" in $g) return 0 ;; esac
      done <<EOF
$globs
EOF
      return 1 ;;
    *) return 0 ;;
  esac
}

_is_testish() { # test file OR test-infra surface
  local p="$1"
  if command -v rt_is_test_path >/dev/null 2>&1; then
    rt_is_test_path "$p" >/dev/null 2>&1 && return 0
  elif [ -n "${TEST_PATH_REGEX:-}" ]; then
    printf '%s' "$p" | grep -Eq "$TEST_PATH_REGEX" && return 0
  fi
  if [ -n "${TEST_SURFACE_REGEX:-}" ]; then
    printf '%s' "$p" | grep -Eq "$TEST_SURFACE_REGEX" && return 0
  fi
  return 1
}

# A revert is NEVER ordered for these, in any mode.
_never_revert() {
  local p="$1" g
  case "$p" in "${CLAUDE_DIR:-.claude}"/*|"${CONTEXT_DIR:-.context}"/*) return 0 ;; esac
  if [ -n "${GOVERNING_CORPUS:-}" ]; then
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      g="${g//$'\r'/}"
      [ "$p" = "$g" ] && return 0
      case "$p" in */"$g") return 0 ;; esac
    done <<EOF
${GOVERNING_CORPUS}
EOF
  fi
  return 1
}

_retries_get() {
  local v; v="$(_read_first_line "$1" 2>/dev/null)"
  case "$v" in (*[!0-9]*|"") v=0 ;; esac
  printf '%s' "$v"
}

_selftest() {
  local fail=0 got
  RT_RAW='{"stop_hook_active":true}'; _stop_hook_active_raw || { echo "FAIL sha true"; fail=1; }
  RT_RAW='{}'; if _stop_hook_active_raw; then echo "FAIL sha absent"; fail=1; fi
  PIPELINE_DIR=".pipeline"; REPO_ROOT="/tmp/rt-selftest-nonexistent"
  got="$(_attribution_mode "")"
  [ "$got" = "weak" ] || { echo "FAIL mode weak: $got"; fail=1; }
  PIPELINE_PARTITION_GLOB="src/p1/**"
  got="$(_attribution_mode "")"
  [ "$got" = "sound" ] || { echo "FAIL mode sound: $got"; fail=1; }
  unset PIPELINE_PARTITION_GLOB
  TEST_PATH_REGEX='(^|/)tests?/'
  _is_testish "tests/test_a.py" || { echo "FAIL is_testish positive"; fail=1; }
  if _is_testish "src/app.py"; then echo "FAIL is_testish negative"; fail=1; fi
  CLAUDE_DIR=".claude"; CONTEXT_DIR=".context"
  _never_revert ".context/SPEC.md" || { echo "FAIL never_revert context"; fail=1; }
  if _never_revert "src/app.py"; then echo "FAIL never_revert src"; fail=1; fi
  if [ "$fail" -eq 0 ]; then echo "subagent-gate.sh selftest PASS"; else echo "subagent-gate.sh selftest FAIL"; fi
  return "$fail"
}

# =========================================================================== #
main() {
  if [ "${1:-}" = "--selftest" ]; then _selftest; exit "$?"; fi

  _read_payload_raw
  if _stop_hook_active_raw; then _allow; fi

  if ! _bootstrap; then
    _emit_block "ratchet subagent-gate: the control layer could not be loaded from ${RT_SELF_DIR}. This gate fails closed and cannot certify that the partition is green or that no test was touched."
  fi

  # We consumed stdin before hooklib was sourced, and rt_payload can only read
  # it once. Hand it over so rt_json_field sees the real payload.
  RT_PAYLOAD_READ=1
  RT_PAYLOAD="$RT_RAW"

  command -v rt_touch_seen >/dev/null 2>&1 && { rt_touch_seen >/dev/null 2>&1 || true; }

  if command -v rt_run_active >/dev/null 2>&1; then
    rt_run_active >/dev/null 2>&1 || _allow
  else
    [ -s "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")" ] || _allow
  fi

  local id mode sid state retry_f scope
  id="$(_dispatch_id)"
  _refresh_exact_baseline "$id"
  mode="$(_attribution_mode "$id")"
  sid="$(_sid)"
  state="$(_state_dir)"
  retry_f="$state/subagent-retries.$sid.${id:-nodispatch}"
  scope="${PIPELINE_TEST_SCOPE:-}"

  local failures="" report=""

  # --- 1. law 1 backstop: no test file touched ---------------------------- #
  local files f rel hits=0 hitlist="" unattributed=0
  files="$(_changed_files)"
  if [ -z "$files" ] && ! _changed_files >/dev/null 2>&1; then
    failures="${failures}git is unavailable or this is not a work tree, so the gate cannot tell whether a test file was touched. Fail closed."$'\n'
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if command -v rt_repo_rel >/dev/null 2>&1; then
      rel="$(rt_repo_rel "$f" 2>/dev/null)"; [ -n "$rel" ] || rel="$f"
    else rel="$f"; fi
    _is_testish "$rel" || continue
    if _is_ours "$rel" "$id" "$mode"; then
      hits=$((hits+1)); hitlist="$hitlist  $rel"$'\n'
    else
      unattributed=$((unattributed+1))
    fi
  done <<EOF
$files
EOF

  if [ "$hits" -gt 0 ]; then
    if [ "$mode" = "exact" ]; then
      local revertable="" reportonly=""
      while IFS= read -r rel; do
        rel="${rel#  }"; [ -n "$rel" ] || continue
        if _never_revert "$rel"; then reportonly="$reportonly  $rel"$'\n'
        else revertable="$revertable  $rel"$'\n'; fi
      done <<EOF
$hitlist
EOF
      failures="${failures}law 1 backstop: this dispatch changed test files. A developer makes red tests green; it does not author or edit them. Attribution mode: exact (diffed against the dispatch baseline)."$'\n'
      [ -n "$revertable" ] && failures="${failures}Revert these, then make the existing tests pass:"$'\n'"$revertable"
      [ -n "$reportonly" ] && failures="${failures}REPORTED ONLY (human-owned or control-layer paths - do NOT revert these yourself, raise them):"$'\n'"$reportonly"
    else
      failures="${failures}law 1 backstop: test files changed during this dispatch. Attribution mode: ${mode} - this gate CANNOT prove they are yours, so it REPORTS them and orders nothing. Do not revert on this evidence; state in your report whether they are yours."$'\n'"$hitlist"
    fi
  fi
  if [ "$unattributed" -gt 0 ]; then
    report="${report}note: ${unattributed} changed test file(s) were excluded as provably not this dispatch's (mode ${mode})."$'\n'
  fi
  if [ "$mode" = "weak" ]; then
    report="${report}ATTRIBUTION IS WEAK: no dispatch baseline and no partition glob on disk for this dispatch. Every finding above is a report, not an accusation. Fix by dispatching through dispatch-baseline.sh <id> <glob...>."$'\n'
    printf 'ratchet subagent-gate: attribution mode WEAK (no %s/dispatch/<id>.tree or .glob).\n' \
      "${PIPELINE_DIR:-.pipeline}" >&2
  fi

  # --- 2. fast scoped suite must be green --------------------------------- #
  local cmd="" outfile code
  outfile="$(_abs "${PIPELINE_DIR:-.pipeline}")/.subagent-gate-out.$$"
  mkdir -p "$(dirname "$outfile")" 2>/dev/null || true
  if [ -n "$scope" ] && [ -n "${SCOPED_TEST_CMD:-}" ]; then
    cmd="$SCOPED_TEST_CMD $scope"
  elif [ -n "${FAST_TEST_CMD:-}" ]; then
    cmd="$FAST_TEST_CMD"
  fi
  if [ -z "$cmd" ]; then
    printf 'ratchet subagent-gate: SKIPPING the suite - the stack pack defines neither SCOPED_TEST_CMD (with PIPELINE_TEST_SCOPE) nor FAST_TEST_CMD.\n' >&2
    _event subagent_suite_skipped "reason=no_command" "dispatch=${id:-}"
  else
    _run_capped "${FAST_TEST_TIMEOUT_SECONDS:-900}" "$cmd" > "$outfile" 2>&1
    code=$?
    _event subagent_suite_ran "exit=$code" "dispatch=${id:-}" "scope=${scope:-}"
    if [ "$code" -ne 0 ]; then
      failures="${failures}the scoped suite is not green (exit $code): ${cmd}"$'\n'"$(tail -n "$TAIL_LINES" "$outfile" 2>/dev/null)"$'\n'
    fi
  fi
  rm -f "$outfile" 2>/dev/null || true

  if [ -z "$failures" ]; then
    rm -f "$retry_f" 2>/dev/null || true
    [ -n "$report" ] && printf 'ratchet subagent-gate notes:\n%s' "$report" >&2
    _event subagent_gate_pass "dispatch=${id:-}" "mode=$mode"
    _allow
  fi

  local n cap="${MAX_SUBAGENT_RETRIES:-3}"
  n="$(_retries_get "$retry_f")"
  if [ "$n" -ge "$cap" ]; then
    printf 'ratchet subagent-gate: cap reached (%s blocks, MAX_SUBAGENT_RETRIES=%s). Handing control back with the partition NOT certified.\n\n%s%s\n' \
      "$n" "$cap" "$failures" "$report" >&2
    _event subagent_gate_cap_exhausted "dispatch=${id:-}" "blocks=$n" "cap=$cap"
    _allow
  fi
  n=$((n+1))
  printf '%s\n' "$n" > "$retry_f" 2>/dev/null || true
  _event subagent_gate_block "dispatch=${id:-}" "attempt=$n" "cap=$cap" "mode=$mode"

  _emit_block "ratchet subagent-gate [developer, block $n of $cap, attribution ${mode}]: this partition is not done.

${failures}${report}"
}

main "$@"
