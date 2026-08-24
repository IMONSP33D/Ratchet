#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/stop-gate.sh
#
# Contract ............ CONTRACT.md §3 (Stop event), §5.2 (gate tiers),
#                       §5.3 (budget = WORK not wall), §5.4 (attribution),
#                       §5.5 (disclosure reprint), §7.6 (manifest format)
# Event ............... Stop   (no matcher)
# Blocking mechanism .. stdout JSON {"decision":"block","reason":"..."} exit 0.
#                       BLOCK means "the agent keeps working".
#                       ALLOW is exit 0 with no decision field.
#                       Halting the run is therefore an ALLOW with a loud
#                       notice - blocking a halted run would be the opposite
#                       of halting it.
# Fail-closed ......... run active + control layer unloadable => BLOCK (§0.3).
#                       No run active => inert, allow (§5.1).
#
# STATE FILES OWNED BY THIS SCRIPT (§0.7 - reader and writer change together)
# ---------------------------------------------------------------------------
# $PIPELINE_DIR/state/stop-retries.<sid>
#     One line, decimal integer, LF-terminated: how many times this gate has
#     BLOCKED in session <sid> during the current run. <sid> is the payload
#     session_id reduced to [A-Za-z0-9_-] and truncated to 40 chars, or
#     "nosession". Cleared by session-start.sh and by gc-prune.sh
#     (start|archive|prune).
#
# $PIPELINE_DIR/state/stop-lastfail.<sid>
#     Exactly two lines:
#       line 1: 64 lowercase hex chars - sha256(failure-text NUL working-diff)
#       line 2: decimal epoch seconds at which it was recorded
#     An identical hash on a later evaluation means the agent retried with no
#     change and got the same failure: the run STOPS rather than looping.
#
# $VERIFY_LAST (.pipeline/verify-last.json) - FROZEN schema, §5.2
#     {"tier","head_sha","dirty_hash","exit","tail","timestamp"}
#       tier       "ship"  - only the ship tier writes this file
#       head_sha   full HEAD sha, or "NO-HEAD"
#       dirty_hash sha256 of (git status --porcelain -uall) + (git diff HEAD),
#                  with every line mentioning "$PIPELINE_DIR/" removed first.
#                  The exclusion is not cosmetic: this gate WRITES into
#                  $PIPELINE_DIR (retry counters, failure hashes, this very
#                  file), so an unfiltered fingerprint changes every time the
#                  gate runs. A staleness marker that invalidates itself
#                  measures nothing, and the repeat-failure stop below - which
#                  uses the same fingerprint - would never fire.
#                  ANY OTHER READER THAT RECOMPUTES THIS MUST FILTER THE SAME
#                  WAY (check_done.py, most of all).
#       exit       integer exit status of VERIFY_CMD
#       exit       0 means the deterministic gate was green
#       tail       last VERIFY_TAIL_LINES lines of combined stdout+stderr
#       timestamp  ISO-8601 UTC, e.g. 2026-08-20T04:05:06Z
#     Written exactly once per ship-tier evaluation. check_done.py, reviewer
#     and security-auditor READ it. Nobody re-runs the suite to learn
#     something already on disk (token doctrine 1).
#
# BUDGET - READ THIS BEFORE "FIXING" A HALT
#     work = (now - RUN_START) - RUN_IDLE   (§5.3)
#     NO SCRIPT MAY EDIT $RUN_START TO CLEAR A HALT. Not this one, not
#     gc-prune.sh, not a helper someone adds later. RUN_START is written once
#     by `gc-prune.sh start` and preserved verbatim by `gc-prune.sh reopen`.
#     Rewinding it would make the budget unfalsifiable, which is the single
#     thing the budget exists to prevent.
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
VERIFY_TAIL_LINES="${VERIFY_TAIL_LINES:-60}"

# --- raw payload, read before anything can fail --------------------------- #
RT_RAW=""
_read_payload_raw() {
  if [ ! -t 0 ]; then RT_RAW="$(cat 2>/dev/null || true)"; fi
  RT_RAW="${RT_RAW//$'\r'/}"
}

# stop_hook_active must be honoured before bootstrap: if the control layer is
# broken we would otherwise block forever.
_stop_hook_active_raw() {
  case "$RT_RAW" in
    *'"stop_hook_active"'*'true'*) return 0 ;;
  esac
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
  local msg="$1"
  if command -v rt_block_json >/dev/null 2>&1; then
    rt_block_json "$msg"
    exit 0
  fi
  printf '{"decision":"block","reason":%s}\n' "$(_json_str "$msg")"
  exit 0
}

_allow() { exit 0; }

# --- bootstrap ------------------------------------------------------------ #
RT_BOOT_OK=0
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

_field() {
  local f="$1" v=""
  if command -v rt_json_field >/dev/null 2>&1; then
    v="$(rt_json_field "$f" 2>/dev/null)"
  fi
  if [ -z "$v" ] && command -v jq >/dev/null 2>&1 && [ -n "$RT_RAW" ]; then
    v="$(printf '%s' "$RT_RAW" | jq -r --arg p "$f" \
      'try getpath($p|split(".")) catch empty | select(.!=null) | tostring' 2>/dev/null)"
  fi
  if [ -z "$v" ] && [ -n "$RT_RAW" ]; then
    local leaf="${f##*.}"
    v="$(printf '%s' "$RT_RAW" \
      | sed -n "s/.*\"${leaf}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      | head -n 1)"
  fi
  printf '%s' "$v"
}

_sid() {
  local s; s="$(_field session_id)"
  s="$(printf '%s' "$s" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_' 2>/dev/null)"
  [ -n "$s" ] || s="nosession"
  printf '%s' "${s:0:40}"
}

_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; return; fi
  if command -v shasum   >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; return; fi
  if command -v openssl  >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'; return; fi
  local py=""
  command -v rt_pick_py >/dev/null 2>&1 && py="$(rt_pick_py 2>/dev/null)"
  if [ -n "$py" ]; then
    "$py" -c 'import sys,hashlib;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null
    return
  fi
  # Fail closed: no hash means we cannot prove "same failure twice", so we
  # emit a sentinel that never matches and the loop-stop simply does not fire.
  printf 'nohash-%s' "$(_now)"
}

_event() {
  local t="$1"; shift
  if command -v rt_event >/dev/null 2>&1; then
    rt_event "$t" "$@" >/dev/null 2>&1 || true
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

_read_first_line() {
  local f="$1" line=""
  [ -r "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || true
  printf '%s' "${line//$'\r'/}"
}

_run_capped() { # <seconds> <cmd string>  -> prints output, returns exit code
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" bash -c "$*" 2>&1
  else
    bash -c "$*" 2>&1
  fi
}

# --- changed-file enumeration --------------------------------------------- #
# Union of: unstaged, staged, untracked-not-ignored, and everything this
# branch has committed since its merge-base with BASE_BRANCH.
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

# Paths always outside the manifest question: run scratch and the learning
# loop. .agent-development is tracked and explicitly scope-exempt; .pipeline
# is run-scoped scratch.
_scope_exempt() {
  local p="$1"
  if command -v rt_path_matches_list >/dev/null 2>&1 && [ -n "${SCOPE_EXEMPT_PREFIXES:-}" ]; then
    rt_path_matches_list "$p" "$SCOPE_EXEMPT_PREFIXES" && return 0
    return 1
  fi
  case "$p" in
    "${PIPELINE_DIR:-.pipeline}"/*) return 0 ;;
    "${DEV_DIR:-.agent-development}"/*) return 0 ;;
    "${EVIDENCE_DIR:-docs/evidence}"/*) return 0 ;;
  esac
  return 1
}

_scope_check() { # prints violations, one per line; returns 1 if any
  local files f rel out="" n=0
  files="$(_changed_files)" || {
    printf 'scope check could not run: git unavailable or not a work tree (fail-closed)\n'
    return 1
  }
  [ -n "$files" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if command -v rt_repo_rel >/dev/null 2>&1; then
      rel="$(rt_repo_rel "$f" 2>/dev/null)"; [ -n "$rel" ] || rel="$f"
    else
      rel="$f"
    fi
    _scope_exempt "$rel" && continue
    if command -v rt_in_manifest >/dev/null 2>&1; then
      rt_in_manifest "$rel" >/dev/null 2>&1 && continue
    else
      # Fail closed: with no manifest reader we cannot prove membership.
      out="$out  $rel (manifest reader unavailable)"$'\n'; n=$((n+1)); continue
    fi
    out="$out  $rel"$'\n'; n=$((n+1))
  done <<EOF
$files
EOF
  if [ "$n" -gt 0 ]; then printf '%s' "$out"; return 1; fi
  return 0
}

# --- disclosures: REMOVED with the escalation channel (2026-08-24) ------------ #
# A "disclosure" was a human ruling that a specific red may ship anyway, minted
# through the approval channel. With no channel there is nothing to mint, and a
# red is simply a red: the gate blocks until it is green or the run stops.
_disclosures_block() { :; }

# --- verify-last writer ---------------------------------------------------- #
# The working-tree fingerprint input. See the dirty_hash note above for why
# $PIPELINE_DIR is filtered out.
_tree_fingerprint() {
  local pd="${PIPELINE_DIR:-.pipeline}"
  { git status --porcelain -uall 2>/dev/null; git diff HEAD 2>/dev/null; } \
    | grep -v -F -- "$pd/"
  return 0
}

_write_verify_last() { # <tier> <exit> <output-file>
  local tier="$1" code="$2" outfile="$3" dest head dirty tail tmp
  dest="$(_abs "${VERIFY_LAST:-.pipeline/verify-last.json}")"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  head="NO-HEAD"
  if command -v git >/dev/null 2>&1; then
    head="$(git rev-parse HEAD 2>/dev/null)"; [ -n "$head" ] || head="NO-HEAD"
  fi
  dirty="$(_tree_fingerprint | _sha256_stdin)"
  tail="$(tail -n "$VERIFY_TAIL_LINES" "$outfile" 2>/dev/null)"
  tmp="$dest.tmp.$$"
  {
    printf '{"tier":%s,"head_sha":%s,"dirty_hash":%s,"exit":%s,"tail":%s,"timestamp":%s}\n' \
      "$(_json_str "$tier")" "$(_json_str "$head")" "$(_json_str "$dirty")" \
      "$code" "$(_json_str "$tail")" "$(_json_str "$(_now_iso)")"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# --- check_done.py --------------------------------------------------------- #
# CLI is owned by another builder. We call the documented form and degrade to
# the bare form if the flag is unrecognised, rather than guessing twice.
_run_check_done() { # <tier> ; prints output, returns exit code
  local tier="$1" py="" script out code
  command -v rt_pick_py >/dev/null 2>&1 && py="$(rt_pick_py 2>/dev/null)"
  script="$(_abs "${HOOKS_DIR:-.claude/hooks}")/check_done.py"
  if [ -z "$py" ] || [ ! -r "$script" ]; then
    printf 'check_done.py or a python 3 interpreter is unavailable - fail closed\n'
    return 90
  fi
  out="$("$py" "$script" --tier "$tier" 2>&1)"; code=$?
  case "$out" in
    *'unrecognized arguments'*|*'no such option'*|*'usage:'*'--tier'*)
      out="$("$py" "$script" 2>&1)"; code=$? ;;
  esac
  printf '%s' "$out"
  return "$code"
}

# --- counters -------------------------------------------------------------- #
_retries_get() {
  local f="$1" v
  v="$(_read_first_line "$f" 2>/dev/null)"
  case "$v" in (*[!0-9]*|"") v=0 ;; esac
  printf '%s' "$v"
}

_selftest() {
  local fail=0 got
  got="$(_json_str 'a"b')"
  case "$got" in *'\"'*) : ;; *) echo "FAIL json_str: $got"; fail=1 ;; esac
  RT_RAW='{"stop_hook_active": true}'
  _stop_hook_active_raw || { echo "FAIL stop_hook_active true"; fail=1; }
  RT_RAW='{"stop_hook_active": false}'
  if _stop_hook_active_raw; then echo "FAIL stop_hook_active false"; fail=1; fi
  PIPELINE_DIR=".pipeline"; DEV_DIR=".agent-development"; EVIDENCE_DIR="docs/evidence"
  _scope_exempt ".pipeline/findings.md" || { echo "FAIL exempt pipeline"; fail=1; }
  if _scope_exempt "src/app.py"; then echo "FAIL exempt src"; fail=1; fi
  got="$(printf 'x' | _sha256_stdin)"
  case "$got" in
    2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881) : ;;
    nohash-*) echo "WARN sha256 unavailable on this host" ;;
    *) echo "FAIL sha256: $got"; fail=1 ;;
  esac
  got="$(_retries_get /nonexistent/counter)"
  [ "$got" = "0" ] || { echo "FAIL retries_get default: $got"; fail=1; }
  if [ "$fail" -eq 0 ]; then echo "stop-gate.sh selftest PASS"; else echo "stop-gate.sh selftest FAIL"; fi
  return "$fail"
}

# =========================================================================== #
main() {
  if [ "${1:-}" = "--selftest" ]; then _selftest; exit "$?"; fi

  _read_payload_raw

  # Loop guard first - honoured even if nothing else loads.
  if _stop_hook_active_raw; then _allow; fi

  if ! _bootstrap; then
    # Fail closed (§0.3): we cannot tell whether a run is active, so we block
    # once with an actionable reason. stop_hook_active above prevents a loop.
    _emit_block "ratchet stop-gate: the control layer could not be loaded (ratchet.config.sh / hooklib.sh unreadable from ${RT_SELF_DIR}). This gate fails closed. Repair the control layer, then stop again."
  fi
  RT_BOOT_OK=1

  # We consumed stdin before hooklib was sourced, and rt_payload can only read
  # it once. Hand it over so rt_json_field sees the real payload.
  RT_PAYLOAD_READ=1
  RT_PAYLOAD="$RT_RAW"

  command -v rt_touch_seen >/dev/null 2>&1 && { rt_touch_seen >/dev/null 2>&1 || true; }

  # --- tier: inert (§5.1) ------------------------------------------------- #
  if command -v rt_run_active >/dev/null 2>&1; then
    if ! rt_run_active >/dev/null 2>&1; then _allow; fi
  else
    [ -s "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")" ] || _allow
  fi

  local milestone sid state retry_f lastfail_f
  milestone="$(_read_first_line "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")" 2>/dev/null)"
  sid="$(_sid)"
  state="$(_state_dir)"
  retry_f="$state/stop-retries.$sid"
  lastfail_f="$state/stop-lastfail.$sid"

  # --- run budget halt (§5.3) --------------------------------------------- #
  # A halt ALLOWS the stop: the run ends, the branch is left intact, and the
  # orchestrator writes the retrospective. See the RUN_START warning above.
  local work=-1 wall=-1
  command -v rt_work_seconds >/dev/null 2>&1 && work="$(rt_work_seconds 2>/dev/null)"
  command -v rt_wall_seconds >/dev/null 2>&1 && wall="$(rt_wall_seconds 2>/dev/null)"
  case "$work" in (*[!0-9]*|"") work=-1 ;; esac
  case "$wall" in (*[!0-9]*|"") wall=-1 ;; esac
  local maxwork="${MAX_RUN_WORK_SECONDS:-28800}" maxwall="${MAX_RUN_WALL_SECONDS:-604800}"
  if [ "$work" -ge 0 ] && [ "$work" -gt "$maxwork" ]; then
    printf 'ratchet: RUN BUDGET HALT - work %ss exceeds MAX_RUN_WORK_SECONDS %ss (milestone %s).\nThe run stops here. Report progress, leave the branch intact, write the retrospective.\nRUN_START must not be edited to clear this halt.\n' \
      "$work" "$maxwork" "${milestone:-unknown}" >&2
    _event run_budget_halt "kind=work" "work=$work" "cap=$maxwork" "milestone=${milestone:-}"
    _allow
  fi
  if [ "$wall" -ge 0 ] && [ "$wall" -gt "$maxwall" ]; then
    printf 'ratchet: RUN BUDGET HALT - wall %ss exceeds MAX_RUN_WALL_SECONDS %ss (milestone %s).\nThe run stops here. RUN_START must not be edited to clear this halt.\n' \
      "$wall" "$maxwall" "${milestone:-unknown}" >&2
    _event run_budget_halt "kind=wall" "wall=$wall" "cap=$maxwall" "milestone=${milestone:-}"
    _allow
  fi

  # --- tier selection (§5.2) ---------------------------------------------- #
  local tier="intermediate"
  [ -r "$(_abs "${READY_TO_SHIP:-.pipeline/ready-to-ship}")" ] && tier="ship"

  local failures="" outfile code
  outfile="$(_abs "${PIPELINE_DIR:-.pipeline}")/.stop-gate-out.$$"
  mkdir -p "$(dirname "$outfile")" 2>/dev/null || true

  if [ "$tier" = "ship" ]; then
    # 1. VERIFY_CMD -> VERIFY_LAST
    if [ -z "${VERIFY_CMD:-}" ]; then
      printf 'ratchet: stop-gate SKIPPING the deterministic gate - the stack pack defines no VERIFY_CMD.\nThis is expected only for the generic stack pack. No verify-last.json was written.\n' >&2
      _event verify_skipped "reason=no_verify_cmd" "tier=ship"
    else
      _run_capped "${VERIFY_TIMEOUT_SECONDS:-3600}" "$VERIFY_CMD" > "$outfile" 2>&1
      code=$?
      if ! _write_verify_last "ship" "$code" "$outfile"; then
        failures="${failures}verify-last.json could not be written (check .pipeline is writable). The ship tier cannot be evidenced without it."$'\n'
      fi
      _event verify_ran "tier=ship" "exit=$code"
      if [ "$code" -ne 0 ]; then
        failures="${failures}VERIFY_CMD failed (exit $code). Last ${VERIFY_TAIL_LINES} lines:"$'\n'"$(tail -n "$VERIFY_TAIL_LINES" "$outfile" 2>/dev/null)"$'\n'
      fi
    fi

    # 2. check_done.py
    local cd_out cd_code
    cd_out="$(_run_check_done ship)"; cd_code=$?
    if [ "$cd_code" -ne 0 ]; then
      failures="${failures}check_done.py --tier ship failed (exit $cd_code):"$'\n'"$cd_out"$'\n'
    fi
  else
    # intermediate tier: fast suite only
    if [ -z "${FAST_TEST_CMD:-}" ]; then
      printf 'ratchet: stop-gate SKIPPING the fast suite - the stack pack defines no FAST_TEST_CMD.\n' >&2
      _event fast_suite_skipped "reason=no_fast_test_cmd" "tier=intermediate"
    else
      _run_capped "${FAST_TEST_TIMEOUT_SECONDS:-900}" "$FAST_TEST_CMD" > "$outfile" 2>&1
      code=$?
      _event fast_suite_ran "tier=intermediate" "exit=$code"
      if [ "$code" -ne 0 ]; then
        failures="${failures}fast suite failed (exit $code). Last ${VERIFY_TAIL_LINES} lines:"$'\n'"$(tail -n "$VERIFY_TAIL_LINES" "$outfile" 2>/dev/null)"$'\n'
      fi
    fi
  fi

  # 3. scope check - both tiers
  local scope_out
  scope_out="$(_scope_check)" || {
    failures="${failures}files changed outside the manifest (${PLAN_FILES:-.pipeline/plan-files.txt} + ${AMENDMENTS:-.pipeline/manifest-amendments.txt}):"$'\n'"$scope_out"$'\n'"Amend with one line per path: <path> <DEC-id> [note], with the matching decision entry in the same commit."$'\n'
  }

  rm -f "$outfile" 2>/dev/null || true

  # --- green ---------------------------------------------------------------#
  if [ -z "$failures" ]; then
    rm -f "$retry_f" "$lastfail_f" 2>/dev/null || true
    _event stop_gate_pass "tier=$tier" "milestone=${milestone:-}"
    _allow
  fi

  # --- repeat-failure stop -------------------------------------------------#
  # Hash the failure text together with the working diff. Same failure, same
  # tree => the last attempt changed nothing, so another attempt cannot help.
  local diff_txt fp prev
  diff_txt="$(_tree_fingerprint)"
  fp="$(printf '%s\000%s' "$failures" "$diff_txt" | _sha256_stdin)"
  prev="$(_read_first_line "$lastfail_f" 2>/dev/null)"
  if [ -n "$prev" ] && [ "$prev" = "$fp" ] && [ "${fp#nohash-}" = "$fp" ]; then
    printf 'ratchet: STOP - identical failure with an unchanged working tree.\nThe previous attempt produced this same failure and changed no files, so another attempt cannot produce a different result.\n\n%s\n%s\n' \
      "$failures" "$(_disclosures_block)" >&2
    _event stop_gate_repeat_stop "tier=$tier" "hash=$fp" "milestone=${milestone:-}"
    _allow
  fi
  printf '%s\n%s\n' "$fp" "$(_now)" > "$lastfail_f" 2>/dev/null || true

  # --- retry cap -----------------------------------------------------------#
  local n cap="${MAX_STOP_RETRIES:-3}"
  n="$(_retries_get "$retry_f")"
  if [ "$n" -ge "$cap" ]; then
    printf 'ratchet: STOP - the stop gate has blocked %s times (MAX_STOP_RETRIES=%s) and the run is still not done.\nA cap is information, not a bell: re-plan, or raise a decision card if the cap reveals something material.\n\n%s\n%s\n' \
      "$n" "$cap" "$failures" "$(_disclosures_block)" >&2
    _event stop_gate_cap_exhausted "tier=$tier" "blocks=$n" "cap=$cap" "milestone=${milestone:-}"
    _allow
  fi
  n=$((n+1))
  printf '%s\n' "$n" > "$retry_f" 2>/dev/null || true
  _event stop_gate_block "tier=$tier" "attempt=$n" "cap=$cap" "milestone=${milestone:-}"

  _emit_block "ratchet stop-gate [$tier tier, block $n of $cap, milestone ${milestone:-unknown}]: the definition of done is not met. Your only task now is making this green.

$failures$(_disclosures_block)"
}

main "$@"
