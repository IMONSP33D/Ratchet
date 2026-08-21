#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/red-gate.sh
#
# Contract ............ CONTRACT.md §3 (SubagentStop / matcher `test-writer`),
#                       §5.4 (attribution), law 1 (red precedes green)
# Event ............... SubagentStop, matcher: test-writer
# Blocking mechanism .. stdout JSON {"decision":"block","reason":"..."} exit 0.
#                       BLOCK means the test-writer keeps working.
# Fail-closed ......... control layer unloadable => BLOCK once. No run active
#                       => inert, allow (§5.1).
#
# WHAT THIS GATE ASSERTS
#   1. The scoped suite EXITS NON-ZERO. The red phase is mechanical here; it
#      is no longer self-reported. A suite that passes has not captured a
#      requirement that does not exist yet.
#   2. No NON-test file was changed. A test-writer that also writes the
#      implementation has made the red phase meaningless.
#   3. The failing test ids are recorded to $RED_BASELINE at the moment they
#      were observed, so the reviewer can compare the agent's self-reported
#      red evidence against a record the agent did not write.
#
#   Green on arrival is NOT silently accepted and is NOT treated as a lie: the
#   gate blocks and asks for an explicit disclosure, because "the test already
#   passes" is sometimes true and is always worth stating.
#
# ATTRIBUTION (§5.4)
#   Same three named modes as subagent-gate.sh. IN ANY MODE BELOW `exact` THIS
#   GATE REPORTS AND NEVER ORDERS A REVERT, and it never orders a revert of a
#   governing-corpus or control-layer path in any mode.
#
# STATE FILES OWNED BY THIS SCRIPT (§0.7)
# ---------------------------------------------------------------------------
# $RED_BASELINE  (.pipeline/red-baseline.txt) - read by the reviewer
#     Line-oriented. Header is "key: value" lines, then a fixed separator,
#     then one failing-test id per line:
#
#       # ratchet red-baseline - written by red-gate.sh, never hand-edited
#       schema: 1
#       timestamp: <ISO-8601 UTC>
#       epoch: <decimal seconds>
#       status: red | green-on-arrival
#       scope: <selector or ->
#       dispatch: <dispatch id or ->
#       mode: <exact|sound|weak>
#       exit: <decimal exit code of RED_TEST_CMD>
#       command: <the command line that was run>
#       count: <number of failing-test lines below>
#       --- failing tests ---
#       <one matched failure line per test, verbatim, whitespace-trimmed>
#
#     A copy is also written to $PIPELINE_DIR/red/<dispatch>.txt so that a
#     later partition's baseline does not erase an earlier one. $RED_BASELINE
#     always holds the MOST RECENT dispatch, which is what the frozen path
#     name promises.
#
# $PIPELINE_DIR/state/red-retries.<sid>.<dispatch>
#     One line, decimal integer: blocks issued for this session + dispatch.
#
# DISCLOSURE INPUT (read, not written, by this script)
# $RED_EVIDENCE (default .pipeline/tdd-red-evidence.md)
#     If the scope is green on arrival, the agent unblocks itself by writing a
#     line beginning "GREEN-ON-ARRIVAL:" followed by the reason. The gate then
#     records status green-on-arrival and allows the stop. Silence does not
#     unblock; a stated reason does.
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
TAIL_LINES="${RED_TAIL_LINES:-40}"

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
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
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
_dispatch_dir() { printf '%s' "$(_abs "${DISPATCH_DIR:-${PIPELINE_DIR:-.pipeline}/dispatch}")"; }
_dispatch_id() {
  local id=""
  if command -v rt_dispatch_id >/dev/null 2>&1; then
    id="$(rt_dispatch_id 2>/dev/null)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  fi
  id="$(_read_first_line "$(_dispatch_dir)/current" 2>/dev/null)"
  [ -n "$id" ] || id="${PIPELINE_DISPATCH_ID:-}"
  printf '%s' "$id"
}
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
  local id="$1" d; d="$(_dispatch_dir)"
  if command -v rt_dispatch_glob >/dev/null 2>&1; then
    rt_dispatch_glob "$id" 2>/dev/null | grep -v '^[[:space:]]*$' && return 0
  fi
  if [ -n "$id" ] && [ -r "$d/$id.glob" ]; then
    sed 's/\r$//' "$d/$id.glob" 2>/dev/null | grep -v '^[[:space:]]*$'; return 0
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
# rt_attributable (hooklib) prints the MODE on stdout and encodes the answer in
# its exit code: 0 = may be this dispatch's work, 1 = provably NOT this
# dispatch's, 2 = undecidable (weak mode). Only exit 1 removes a path from the
# report. Treating 2 as "not ours" would turn "we cannot tell" into "all
# clear", which is the exact inversion this gate exists to prevent.
_is_ours() {
  local p="$1" id="$2" mode="$3" globs g rc
  if command -v rt_attributable >/dev/null 2>&1; then
    rt_attributable "$p" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] && return 1
    return 0
  fi
  case "$mode" in
    exact)
      if [ -r "$RT_SELF_DIR/dispatch-baseline.sh" ]; then
        bash "$RT_SELF_DIR/dispatch-baseline.sh" changed "$id" 2>/dev/null | grep -Fxq -- "$p" && return 0
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
_is_testish() {
  local p="$1"
  if command -v rt_is_test_path >/dev/null 2>&1; then
    rt_is_test_path "$p" >/dev/null 2>&1 && return 0
  elif [ -n "${TEST_PATH_REGEX:-}" ]; then
    printf '%s' "$p" | grep -Eq "$TEST_PATH_REGEX" && return 0
  fi
  [ -n "${TEST_SURFACE_REGEX:-}" ] && printf '%s' "$p" | grep -Eq "$TEST_SURFACE_REGEX" && return 0
  return 1
}
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

# Extract failing-test ids from suite output using the stack pack regex.
_failing_ids() { # <output-file>
  local f="$1"
  [ -r "$f" ] || return 0
  if [ -n "${FAILURE_LINE_REGEX:-}" ]; then
    grep -E "$FAILURE_LINE_REGEX" "$f" 2>/dev/null \
      | sed 's/\r$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -v '^$' | sort -u
  fi
  return 0
}

_write_red_baseline() { # <status> <exit> <scope> <dispatch> <mode> <cmd> <ids-file>
  local status="$1" code="$2" scope="$3" id="$4" mode="$5" cmd="$6" idsf="$7"
  local dest tmp count copydir
  dest="$(_abs "${RED_BASELINE:-.pipeline/red-baseline.txt}")"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  count="$(grep -c . "$idsf" 2>/dev/null)"; case "$count" in (*[!0-9]*|"") count=0 ;; esac
  tmp="$dest.tmp.$$"
  {
    printf '# ratchet red-baseline - written by red-gate.sh, never hand-edited\n'
    printf 'schema: 1\n'
    printf 'timestamp: %s\n' "$(_now_iso)"
    printf 'epoch: %s\n' "$(_now)"
    printf 'status: %s\n' "$status"
    printf 'scope: %s\n' "${scope:--}"
    printf 'dispatch: %s\n' "${id:--}"
    printf 'mode: %s\n' "$mode"
    printf 'exit: %s\n' "$code"
    printf 'command: %s\n' "$cmd"
    printf 'count: %s\n' "$count"
    printf -- '--- failing tests ---\n'
    cat "$idsf" 2>/dev/null
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  copydir="$(_abs "${PIPELINE_DIR:-.pipeline}")/red"
  mkdir -p "$copydir" 2>/dev/null || true
  cp -f "$dest" "$copydir/${id:-nodispatch}.txt" 2>/dev/null || true
  return 0
}

_green_disclosed() {
  local f
  f="$(_abs "${RED_EVIDENCE:-${PIPELINE_DIR:-.pipeline}/tdd-red-evidence.md}")"
  [ -r "$f" ] || return 1
  grep -q '^[[:space:]]*GREEN-ON-ARRIVAL:[[:space:]]*[^[:space:]]' "$f" 2>/dev/null
}

_selftest() {
  local fail=0 got tmp
  RT_RAW='{"stop_hook_active":true}'; _stop_hook_active_raw || { echo "FAIL stop_hook_active"; fail=1; }
  PIPELINE_DIR=".pipeline"; REPO_ROOT="/tmp/rt-selftest-nonexistent"
  got="$(_attribution_mode "")"; [ "$got" = "weak" ] || { echo "FAIL mode: $got"; fail=1; }
  tmp="$(mktemp 2>/dev/null || echo /tmp/rt-red-$$)"
  printf 'FAILED tests/test_a.py::test_one\nok\nFAILED tests/test_b.py::test_two\n' > "$tmp"
  FAILURE_LINE_REGEX='^FAILED '
  got="$(_failing_ids "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "2" ] || { echo "FAIL failing_ids count: $got"; fail=1; }
  FAILURE_LINE_REGEX='^NEVERMATCHES '
  got="$(_failing_ids "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "0" ] || { echo "FAIL failing_ids negative: $got"; fail=1; }
  rm -f "$tmp" 2>/dev/null
  REPO_ROOT="/tmp/rt-selftest-nonexistent"; RED_EVIDENCE=".pipeline/nope.md"
  if _green_disclosed; then echo "FAIL green_disclosed on missing file"; fail=1; fi
  if [ "$fail" -eq 0 ]; then echo "red-gate.sh selftest PASS"; else echo "red-gate.sh selftest FAIL"; fi
  return "$fail"
}

# =========================================================================== #
main() {
  if [ "${1:-}" = "--selftest" ]; then _selftest; exit "$?"; fi

  _read_payload_raw
  if _stop_hook_active_raw; then _allow; fi

  if ! _bootstrap; then
    _emit_block "ratchet red-gate: the control layer could not be loaded from ${RT_SELF_DIR}. This gate fails closed - the red phase cannot be certified, and law 1 depends on it being mechanical."
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
  id="$(_dispatch_id)"; _refresh_exact_baseline "$id"
  mode="$(_attribution_mode "$id")"; sid="$(_sid)"
  state="$(_state_dir)"; retry_f="$state/red-retries.$sid.${id:-nodispatch}"
  scope="${PIPELINE_TEST_SCOPE:-}"

  local failures="" report=""

  # --- 1. run the scoped suite; it MUST be red ---------------------------- #
  local cmd="" outfile code=0 idsf status="red"
  outfile="$(_abs "${PIPELINE_DIR:-.pipeline}")/.red-gate-out.$$"
  idsf="$(_abs "${PIPELINE_DIR:-.pipeline}")/.red-gate-ids.$$"
  mkdir -p "$(dirname "$outfile")" 2>/dev/null || true
  : > "$idsf" 2>/dev/null || true

  if [ -n "${RED_TEST_CMD:-}" ]; then
    cmd="$RED_TEST_CMD${scope:+ $scope}"
  elif [ -n "${SCOPED_TEST_CMD:-}" ] && [ -n "$scope" ]; then
    cmd="$SCOPED_TEST_CMD $scope"
  elif [ -n "${FAST_TEST_CMD:-}" ]; then
    cmd="$FAST_TEST_CMD"
  fi

  if [ -z "$cmd" ]; then
    # Loud skip: with no command there is no red phase to prove. The gate does
    # not invent one, and it does not pretend the phase happened.
    printf 'ratchet red-gate: SKIPPING the red phase - the stack pack defines no RED_TEST_CMD/SCOPED_TEST_CMD/FAST_TEST_CMD. No red baseline was written.\n' >&2
    _event red_gate_skipped "reason=no_command" "dispatch=${id:-}"
    _allow
  fi

  _run_capped "${RED_TIMEOUT_SECONDS:-900}" "$cmd" > "$outfile" 2>&1
  code=$?
  _failing_ids "$outfile" > "$idsf" 2>/dev/null || true
  _event red_gate_ran "exit=$code" "dispatch=${id:-}" "scope=${scope:-}"

  if [ "$code" -eq 0 ]; then
    # Green on arrival: real sometimes, silent never.
    if _green_disclosed; then
      status="green-on-arrival"
      report="${report}green on arrival, explicitly disclosed in ${RED_EVIDENCE:-${PIPELINE_DIR:-.pipeline}/tdd-red-evidence.md}. Recorded as such in the red baseline."$'\n'
      _event red_gate_green_disclosed "dispatch=${id:-}" "scope=${scope:-}"
    else
      _write_red_baseline "green-on-arrival-undisclosed" "$code" "$scope" "$id" "$mode" "$cmd" "$idsf"
      rm -f "$outfile" "$idsf" 2>/dev/null || true
      local ng cap_ng="${MAX_SUBAGENT_RETRIES:-3}"
      ng="$(_retries_get "$retry_f")"
      if [ "$ng" -ge "$cap_ng" ]; then
        printf 'ratchet red-gate: cap reached (%s blocks) with the scope still green and undisclosed.\n' "$ng" >&2
        _event red_gate_cap_exhausted "dispatch=${id:-}" "blocks=$ng"
        _allow
      fi
      ng=$((ng+1)); printf '%s\n' "$ng" > "$retry_f" 2>/dev/null || true
      _event red_gate_block "reason=green_on_arrival" "dispatch=${id:-}" "attempt=$ng"
      _emit_block "ratchet red-gate [test-writer, block $ng of $cap_ng]: the scoped suite PASSES, so there is no red phase to certify.

Command: $cmd
Scope:   ${scope:--}

Either the test does not yet capture a requirement the code fails to meet - write the failing assertion - or the behaviour genuinely already exists. The second case is legitimate and must be SAID, not assumed: append a line to ${RED_EVIDENCE:-${PIPELINE_DIR:-.pipeline}/tdd-red-evidence.md} of the exact form

    GREEN-ON-ARRIVAL: <why this scope is already green, and what the test now protects>

and stop again. Silence does not clear this block; a stated reason does."
    fi
  fi

  # --- 2. no NON-test file may have changed ------------------------------- #
  local files f rel hits=0 hitlist="" excluded=0
  files="$(_changed_files)"
  if [ -z "$files" ] && ! _changed_files >/dev/null 2>&1; then
    failures="${failures}git is unavailable or this is not a work tree, so the gate cannot tell whether an implementation file was changed. Fail closed."$'\n'
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if command -v rt_repo_rel >/dev/null 2>&1; then
      rel="$(rt_repo_rel "$f" 2>/dev/null)"; [ -n "$rel" ] || rel="$f"
    else rel="$f"; fi
    _is_testish "$rel" && continue
    case "$rel" in
      "${PIPELINE_DIR:-.pipeline}"/*|"${DEV_DIR:-.agent-development}"/*) continue ;;
    esac
    if _is_ours "$rel" "$id" "$mode"; then
      hits=$((hits+1)); hitlist="$hitlist  $rel"$'\n'
    else
      excluded=$((excluded+1))
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
      failures="${failures}the test-writer changed non-test files. Red must be authored against the code as it stands; writing the implementation here makes the red phase prove nothing. Attribution mode: exact."$'\n'
      [ -n "$revertable" ] && failures="${failures}Revert these:"$'\n'"$revertable"
      [ -n "$reportonly" ] && failures="${failures}REPORTED ONLY (human-owned or control-layer paths - do NOT revert these yourself, raise them):"$'\n'"$reportonly"
    else
      failures="${failures}non-test files changed during this dispatch. Attribution mode: ${mode} - this gate CANNOT prove they are yours, so it REPORTS them and orders nothing. Do not revert on this evidence; say in your report whether they are yours."$'\n'"$hitlist"
    fi
  fi
  [ "$excluded" -gt 0 ] && report="${report}note: ${excluded} changed non-test file(s) excluded as provably not this dispatch's (mode ${mode})."$'\n'
  if [ "$mode" = "weak" ]; then
    report="${report}ATTRIBUTION IS WEAK: no dispatch baseline and no partition glob on disk. Findings above are reports, not accusations."$'\n'
    printf 'ratchet red-gate: attribution mode WEAK.\n' >&2
  fi

  # --- 3. record the baseline the reviewer will check against ------------- #
  if ! _write_red_baseline "$status" "$code" "$scope" "$id" "$mode" "$cmd" "$idsf"; then
    failures="${failures}the red baseline could not be written to ${RED_BASELINE:-.pipeline/red-baseline.txt}. Without it the reviewer has nothing to compare your red evidence against."$'\n'
  fi
  local n_ids; n_ids="$(grep -c . "$idsf" 2>/dev/null)"
  case "$n_ids" in (*[!0-9]*|"") n_ids=0 ;; esac
  if [ "$status" = "red" ] && [ "$n_ids" -eq 0 ]; then
    report="${report}the suite exited ${code} but FAILURE_LINE_REGEX matched no line, so the baseline lists no test ids. The red phase is certified by the exit code; the id list is empty and the reviewer will see that."$'\n'
  fi

  rm -f "$outfile" "$idsf" 2>/dev/null || true

  if [ -z "$failures" ]; then
    rm -f "$retry_f" 2>/dev/null || true
    [ -n "$report" ] && printf 'ratchet red-gate notes:\n%s' "$report" >&2
    _event red_gate_pass "dispatch=${id:-}" "mode=$mode" "status=$status" "failing=$n_ids"
    _allow
  fi

  local n cap="${MAX_SUBAGENT_RETRIES:-3}"
  n="$(_retries_get "$retry_f")"
  if [ "$n" -ge "$cap" ]; then
    printf 'ratchet red-gate: cap reached (%s blocks, cap %s). Handing back with the red phase NOT certified.\n\n%s%s\n' \
      "$n" "$cap" "$failures" "$report" >&2
    _event red_gate_cap_exhausted "dispatch=${id:-}" "blocks=$n" "cap=$cap"
    _allow
  fi
  n=$((n+1)); printf '%s\n' "$n" > "$retry_f" 2>/dev/null || true
  _event red_gate_block "dispatch=${id:-}" "attempt=$n" "cap=$cap" "mode=$mode"

  _emit_block "ratchet red-gate [test-writer, block $n of $cap, attribution ${mode}]: the red phase is not clean.

${failures}${report}"
}

main "$@"
