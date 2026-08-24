#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/session-start.sh
#
# Contract ............ CONTRACT.md §3 (SessionStart), §5.3 (WORK budget),
#                       §5.1 (run lifecycle)
# Event ............... SessionStart (no matcher)
# Blocking mechanism .. NONE. This hook cannot block and MUST NOT crash a
#                       session. Every path emits valid JSON and exits 0:
#                         {"hookSpecificOutput":{"hookEventName":"SessionStart",
#                          "additionalContext":"..."}}
#                       If everything else fails it emits a one-line context
#                       saying the control layer did not load - which is
#                       itself the most useful thing it could say.
#
# WHAT IT INJECTS, IN ORDER
#   1. The run banner: milestone, work elapsed vs MAX_RUN_WORK_SECONDS, wall
#      elapsed vs MAX_RUN_WALL_SECONDS, and whether a run is active at all.
#   2. $CONTEXT_LIVE, if present, capped at CAP_CONTEXT_LIVE_LINES (the
#      orchestrator's working state; gc-prune.sh is what keeps the FILE
#      itself under this size, this cap is the injection's own backstop).
#   3. $ACTIVE_LESSONS, capped at CAP_ACTIVE_LESSONS_LINES - the only retro
#      artifact any agent reads. This is the ONLY path either file reaches a
#      session: doctrine/CLAUDE.md does not @-import them (R9) precisely so
#      there is one capped copy, not an uncapped second one alongside it.
#   4. Rows of $PENDING_ACTIONS at recurrence >= 3, OR filed at install (the
#      three install-time rows are prerequisites, not incidents, and their
#      recurrence never climbs on its own -- a pure threshold would never
#      print them).
#   5. Three control-layer self-test probes: test_hooks.py --smoke; the
#      the pager (RATCHET_WEBHOOK_URL set, https, notify.sh
#      present). Probing before any of them is needed is the point - a
#      control layer that is broken at 03:00 on the tenth block, or a pager
#      that pages nobody, should have said so at 09:00 when the session
#      opened.
#
# SIDE EFFECTS (this hook is a run-lifecycle PARTICIPANT, not an owner)
#   - Clears stale per-session counters written by the Stop/SubagentStop gates
#     ($PIPELINE_DIR/state/*): counters for THIS session id, and any counter
#     file older than STATE_STALE_DAYS days. A fresh session starts at zero
#     blocks; a cap inherited from a dead session is a phantom.
#   - Folds the idle gap via rt_touch_seen (§5.3). It never writes RUN_START,
#     RUN_ACTIVE or RUN_IDLE directly - gc-prune.sh owns those four
#     transitions and nothing else may write them.
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
STATE_STALE_DAYS="${STATE_STALE_DAYS:-2}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT_SECONDS:-60}"

RT_RAW=""
CTX=""

_add()  { CTX="${CTX}$1"$'\n'; }
_addf() { CTX="${CTX}$(printf "$@")"$'\n'; }

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

# Single exit path. Called from a trap too, so a crash still emits JSON.
# RT_EMITTED makes it idempotent: main calls _emit explicitly, which exits,
# which fires the EXIT trap, which calls _emit again. Without the guard the
# session would receive two JSON objects and parse neither.
RT_EMITTED=0
_emit() {
  [ "$RT_EMITTED" -eq 1 ] && exit 0
  RT_EMITTED=1
  local body="${CTX:-ratchet: no context available.}"
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
    "$(_json_str "$body")"
  exit 0
}
trap '_emit' EXIT

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
_hms() { # seconds -> "1h 23m"
  local s="${1:-0}"
  case "$s" in (*[!0-9]*|"") printf 'unknown'; return 0 ;; esac
  printf '%sh %sm' "$((s/3600))" "$(((s%3600)/60))"
}
_pct() { # <value> <cap> -> integer percent, "?" if unusable
  local v="${1:-}" c="${2:-}"
  case "$v$c" in (*[!0-9]*|"") printf '?'; return 0 ;; esac
  [ "$c" -gt 0 ] || { printf '?'; return 0; }
  printf '%s' "$(( v * 100 / c ))"
}

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

_clear_stale_counters() {
  local d sid f
  d="$(_abs "${PIPELINE_DIR:-.pipeline}")/state"
  [ -d "$d" ] || return 0
  sid="$(_field session_id)"
  sid="$(printf '%s' "$sid" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_' 2>/dev/null)"
  sid="${sid:0:40}"
  if [ -n "$sid" ]; then
    for f in "$d"/*."$sid" "$d"/*."$sid".*; do
      [ -e "$f" ] && rm -f "$f" 2>/dev/null
    done
  fi
  if command -v find >/dev/null 2>&1; then
    find "$d" -type f -mtime "+${STATE_STALE_DAYS}" -exec rm -f {} \; 2>/dev/null || true
  fi
  return 0
}

# Rows of PENDING_ACTIONS that must print at SessionStart: recurrence >= 3,
# OR filed at install time. The three rows install.sh pre-files (branch
# protection, unfilled contracts, no webhook) all ship at recurrence 0 --
# they are prerequisites, not repeated incidents, and recurrence never climbs
# on its own (only a retro increments it, once per run). A pure recurrence>=3
# filter therefore never prints them, which is exactly the failure this
# register exists to prevent: three install-time warnings the source
# pipeline's own webhook row (see "why it blocks" below) says paged nobody
# for five runs because nothing printed them. "filed == install" is a second,
# independent reason to print -- not a threshold to game at filing time.
_pending_must_print() {
  local f="$1" hdr_line="" rcol=0 fcol=0 i n filed line cell out=""
  [ -r "$f" ] || return 0
  # A header cell is a LABEL: it contains the column word and no digits. That
  # stops a data row like "| ... recurrence x 5 |" from being mistaken for
  # the header and skipped - which would drop exactly the rows this function
  # exists to find.
  hdr_line="$(grep -n -i '^|.*recurrence' "$f" 2>/dev/null | head -n 1)"
  local hdr="" cand=""
  if [ -n "$hdr_line" ]; then
    cand="${hdr_line#*:}"
    i=0
    local IFSOLD="$IFS"; IFS='|'
    for cell in $cand; do
      i=$((i+1))
      case "$(printf '%s' "$cell" | tr 'A-Z' 'a-z')" in
        *[0-9]*) continue ;;
        *recurrence*) rcol=$i ;;
        *filed*) fcol=$i ;;
      esac
    done
    [ "$rcol" -gt 0 ] && hdr="$cand"
    IFS="$IFSOLD"
  fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      '|'*) : ;;
      *) continue ;;
    esac
    # Skip the header row (matched by identity, not by containing the word
    # "recurrence" - a data row is allowed to say "recurrence x 5" and an
    # over-eager skip here would drop exactly the rows this function exists
    # to find) and the ---|--- separator row.
    [ -n "$hdr" ] && [ "$line" = "$hdr" ] && continue
    case "$line" in
      *---*) continue ;;
    esac
    n=""
    if [ "$rcol" -gt 0 ]; then
      n="$(printf '%s' "$line" | awk -F'|' -v c="$rcol" '{gsub(/[^0-9]/,"",$c); print $c}' 2>/dev/null)"
    fi
    if [ -z "$n" ]; then
      n="$(printf '%s' "$line" | sed -n 's/.*[Rr]ecurrence[^0-9]\{0,6\}\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    fi
    filed=""
    if [ "$fcol" -gt 0 ]; then
      filed="$(printf '%s' "$line" | awk -F'|' -v c="$fcol" '{gsub(/^[ \t]+|[ \t]+$/,"",$c); print $c}' 2>/dev/null | tr 'A-Z' 'a-z')"
    fi
    case "$n" in (*[!0-9]*|"") n=0 ;; esac
    if [ "$n" -ge 3 ] || [ "$filed" = "install" ]; then
      out="${out}${line}"$'\n'
    fi
  done < "$f"
  printf '%s' "$out"
}

# _webhook_probe - can a stopped run actually page anyone?
#
# PENDING-HUMAN-ACTIONS.md's webhook-never-configured row has always claimed
# "session-start.sh warns at every run start" -- this is that warning. Without
# it, RATCHET_WEBHOOK_URL unset was a silent default: the harness worked, an
# unattended halt just paged nobody, and nothing said so until this probe.
# This checks configuration only (unset, non-https, or notify.sh missing) --
# it never fires a real notification. Use `notify.sh --test` for that.
_webhook_probe() {
  local url="${RATCHET_WEBHOOK_URL:-}" issues=""
  if [ -z "$url" ]; then
    issues="UNSET - no RATCHET_WEBHOOK_URL. A stopped or escalated unattended run pages nobody; you find out by going and looking. Set it, then prove the path: .claude/hooks/notify.sh --test"
  elif [ "${url#https://}" = "$url" ]; then
    issues="NOT HTTPS - RATCHET_WEBHOOK_URL must be https; notify.sh refuses to send to it."
  elif [ ! -r "$RT_SELF_DIR/notify.sh" ]; then
    issues="MISSING - .claude/hooks/notify.sh is not present; nothing can send to the webhook even though it is configured."
  fi
  if [ -n "$issues" ]; then printf 'FAIL - webhook %s' "$issues"; return 0; fi
  printf 'PASS - webhook configured (https, notify.sh present)'
}

# _capped_file <path> <cap> - read a file, normalize CRLF, truncate to <cap>
# lines. Shared by the context-live and active-lessons injections so both go
# through the SAME cap enforcement instead of each hand-rolling its own
# `head -n` -- the drift between "capped" and "verbatim" here is exactly the
# R9 audit finding: an @-import path used to bypass this entirely.
_capped_file() {
  local f="$1" cap="$2"
  [ -r "$f" ] || return 1
  sed 's/\r$//' "$f" 2>/dev/null | head -n "${cap:-100}"
}

_smoke_probe() {
  local py="" script out code
  command -v rt_pick_py >/dev/null 2>&1 && py="$(rt_pick_py 2>/dev/null)"
  script="$(_abs "${HOOKS_DIR:-.claude/hooks}")/test_hooks.py"
  if [ -z "$py" ]; then
    printf 'FAIL - no python 3 interpreter found (rt_pick_py returned nothing). Every python gate in this harness is currently unable to run.'
    return 1
  fi
  if [ ! -r "$script" ]; then
    printf 'FAIL - %s is missing. The control layer cannot self-test.' "$script"
    return 1
  fi
  if command -v timeout >/dev/null 2>&1; then
    # We ARE bash, so we know a working one; the Python suite would otherwise
    # re-resolve it and can land on the WSL relay on Windows.
    [ -n "${RATCHET_BASH:-}" ] || export RATCHET_BASH="${BASH:-$(command -v bash 2>/dev/null)}"
    out="$(timeout "$SMOKE_TIMEOUT" "$py" "$script" --smoke 2>&1)"; code=$?
  else
    out="$("$py" "$script" --smoke 2>&1)"; code=$?
  fi
  if [ "$code" -eq 0 ]; then
    printf 'PASS - test_hooks.py --smoke'
    return 0
  fi
  printf 'FAIL (exit %s) - test_hooks.py --smoke:\n%s' "$code" "$(printf '%s' "$out" | tail -n 20)"
  return 1
}

_selftest() {
  local fail=0 got tmp
  got="$(_hms 3720)"; [ "$got" = "1h 2m" ] || { echo "FAIL hms: $got"; fail=1; }
  got="$(_hms "abc")"; [ "$got" = "unknown" ] || { echo "FAIL hms bad: $got"; fail=1; }
  got="$(_pct 50 200)"; [ "$got" = "25" ] || { echo "FAIL pct: $got"; fail=1; }
  got="$(_pct 50 0)"; [ "$got" = "?" ] || { echo "FAIL pct zero: $got"; fail=1; }
  tmp="$(mktemp 2>/dev/null || echo /tmp/rt-ss-$$)"
  {
    printf '| name | filed | status | recurrence |\n'
    printf '|---|---|---|---|\n'
    printf '| gate-blames-wrong-actor | 2026-01-01 | open | 4 |\n'
    printf '| pager-never-fires | 2026-01-01 | open | 1 |\n'
  } > "$tmp"
  got="$(_pending_must_print "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "1" ] || { echo "FAIL pending table parse: $got"; fail=1; }
  printf 'a note with recurrence: 3 inside\n' > "$tmp"
  got="$(_pending_must_print "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "0" ] || { echo "FAIL pending non-table line must not match: $got"; fail=1; }
  printf '| free form recurrence x 5 |\n' > "$tmp"
  got="$(_pending_must_print "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "1" ] || { echo "FAIL pending freetext parse: $got"; fail=1; }
  {
    printf '| name | filed | status | recurrence |\n'
    printf '|---|---|---|---|\n'
    printf '| webhook-never-configured | install | open | 0 |\n'
    printf '| unrelated-low-recurrence | 2026-01-01 | open | 1 |\n'
  } > "$tmp"
  got="$(_pending_must_print "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "1" ] || { echo "FAIL pending filed=install must print at recurrence 0: $got"; fail=1; }
  rm -f "$tmp" 2>/dev/null
  got="$(_json_str 'a
b')"
  case "$got" in *'\n'*) : ;; *) echo "FAIL json_str newline: $got"; fail=1 ;; esac
  tmp="$(mktemp 2>/dev/null || echo /tmp/rt-ss-$$)"
  printf 'one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n' > "$tmp"
  got="$(_capped_file "$tmp" 3 | wc -l | tr -d ' ')"
  [ "$got" = "3" ] || { echo "FAIL capped_file did not truncate: $got"; fail=1; }
  got="$(_capped_file "$tmp" 3 | tail -n 1)"
  [ "$got" = "three" ] || { echo "FAIL capped_file kept wrong lines or CRLF: [$got]"; fail=1; }
  got="$(_capped_file "$tmp" 100 | wc -l | tr -d ' ')"
  [ "$got" = "5" ] || { echo "FAIL capped_file truncated under cap: $got"; fail=1; }
  got="$(_capped_file /nonexistent/no-such-file 10)"
  [ -z "$got" ] || { echo "FAIL capped_file on missing file should be empty: [$got]"; fail=1; }
  rm -f "$tmp" 2>/dev/null
  if [ "$fail" -eq 0 ]; then echo "session-start.sh selftest PASS"; else echo "session-start.sh selftest FAIL"; fi
  return "$fail"
}

# =========================================================================== #
main() {
  if [ "${1:-}" = "--selftest" ]; then trap - EXIT; _selftest; exit "$?"; fi

  [ -t 0 ] || RT_RAW="$(cat 2>/dev/null || true)"
  RT_RAW="${RT_RAW//$'\r'/}"

  if ! _bootstrap; then
    CTX="ratchet: the control layer did not load (ratchet.config.sh / hooklib.sh unreadable from ${RT_SELF_DIR}). Hooks that fail closed will block. Repair the control layer before starting work."
    _emit
  fi

  # We consumed stdin before hooklib was sourced, and rt_payload can only read
  # it once. Hand it over so rt_json_field sees the real payload.
  RT_PAYLOAD_READ=1
  RT_PAYLOAD="$RT_RAW"

  command -v rt_touch_seen >/dev/null 2>&1 && { rt_touch_seen >/dev/null 2>&1 || true; }
  _clear_stale_counters

  local active=0 milestone="" work=-1 wall=-1
  if command -v rt_run_active >/dev/null 2>&1; then
    rt_run_active >/dev/null 2>&1 && active=1
  else
    [ -s "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")" ] && active=1
  fi
  milestone="$(_read_first_line "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")" 2>/dev/null)"
  command -v rt_work_seconds >/dev/null 2>&1 && work="$(rt_work_seconds 2>/dev/null)"
  command -v rt_wall_seconds >/dev/null 2>&1 && wall="$(rt_wall_seconds 2>/dev/null)"
  case "$work" in (*[!0-9]*|"") work=-1 ;; esac
  case "$wall" in (*[!0-9]*|"") wall=-1 ;; esac

  _add "# ratchet - session context (${RT_VERSION:-unknown}) for ${PROJECT_NAME:-this project}"
  _add ""
  if [ "$active" -eq 1 ]; then
    _add "## Run banner"
    _add "- Run: ACTIVE - milestone ${milestone:-unknown}"
    if [ "$work" -ge 0 ]; then
      _addf -- "- Work elapsed: %s of %s (%s%%) - idle gaps over %ss are folded out" \
        "$(_hms "$work")" "$(_hms "${MAX_RUN_WORK_SECONDS:-28800}")" \
        "$(_pct "$work" "${MAX_RUN_WORK_SECONDS:-28800}")" "${IDLE_THRESHOLD_SECONDS:-900}"
    else
      _add "- Work elapsed: not measurable (hooklib did not report rt_work_seconds)"
    fi
    if [ "$wall" -ge 0 ]; then
      _addf -- "- Wall elapsed: %s of %s (%s%%)" \
        "$(_hms "$wall")" "$(_hms "${MAX_RUN_WALL_SECONDS:-604800}")" \
        "$(_pct "$wall" "${MAX_RUN_WALL_SECONDS:-604800}")"
    fi
    if [ -r "$(_abs "${READY_TO_SHIP:-.pipeline/ready-to-ship}")" ]; then
      _add "- Gate tier: SHIP (ready-to-ship present) - the Stop gate runs the full deterministic gate"
    else
      _add "- Gate tier: intermediate (no ready-to-ship) - the Stop gate runs the fast suite and the scope check"
    fi
  else
    _add "## Run banner"
    _add "- Run: NONE ACTIVE. Scope checks and the Stop gate's definition-of-done checks are INERT."
    _add "- Start one with: .claude/hooks/gc-prune.sh start <milestone-id>"
  fi
  _add ""

  local f content
  f="$(_abs "${CONTEXT_LIVE:-.pipeline/context-live.md}")"
  content="$(_capped_file "$f" "${CAP_CONTEXT_LIVE_LINES:-150}")"
  [ -n "$content" ] && { _add "## Live context (${CONTEXT_LIVE:-.pipeline/context-live.md}, capped at ${CAP_CONTEXT_LIVE_LINES:-150} lines)"; _add ""; _add "$content"; _add ""; }

  f="$(_abs "${ACTIVE_LESSONS:-.agent-development/ACTIVE-LESSONS.md}")"
  content="$(_capped_file "$f" "${CAP_ACTIVE_LESSONS_LINES:-100}")"
  [ -n "$content" ] && { _add "## Active lessons (read at run start, every run)"; _add ""; _add "$content"; _add ""; }

  f="$(_abs "${PENDING_ACTIONS:-.agent-development/PENDING-HUMAN-ACTIONS.md}")"
  content="$(_pending_must_print "$f")"
  if [ -n "$content" ]; then
    _add "## Pending human actions (recurrence 3+, or filed at install)"
    _add ""
    _add "A lesson that has recurred three times is a systemic defect, not a note. A row"
    _add "filed at install is a prerequisite the harness cannot function safely without,"
    _add "not an incident count -- it prints every run until DONE, regardless of recurrence."
    _add ""
    _add "$content"
    _add ""
  fi

  local probe pager
  probe="$(_smoke_probe)"
  pager="$(_webhook_probe)"
  _add "## Control-layer self test"
  _add ""
  _add "$probe"
  _add "$pager"
  _add ""
  case "$probe" in
    FAIL*) _add "The control layer is probing FAILED at session start. Gates that fail closed will block, and a block you cannot clear is the expected consequence. Fix this before dispatching anything." ;;
  esac
  case "$pager" in
    FAIL*) _add "No pager is configured. A stopped or escalated unattended run will NOT reach a human -- see webhook-never-configured in PENDING-HUMAN-ACTIONS.md." ;;
  esac

  if [ -r "$RT_SELF_DIR/pipeline-event.sh" ]; then
    bash "$RT_SELF_DIR/pipeline-event.sh" session_start \
      "milestone=${milestone:-}" "active=$active" "work=$work" "wall=$wall" \
      "smoke=$(case "$probe" in PASS*) echo pass ;; *) echo fail ;; esac)" \
      "pager=$(case "$pager" in PASS*) echo pass ;; *) echo fail ;; esac)" >/dev/null 2>&1 || true
  fi

  _emit
}

main "$@"
