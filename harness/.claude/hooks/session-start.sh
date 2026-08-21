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
#   2. $CONTEXT_LIVE verbatim, if present (the orchestrator's working state).
#   3. $ACTIVE_LESSONS - the only retro artifact any agent reads.
#   4. Rows of $PENDING_ACTIONS with recurrence >= 3. A lesson that has
#      recurred three times is a systemic defect, not a note.
#   5. A control-layer self-test probe: test_hooks.py --smoke, pass or fail.
#      Probing the channel before it is needed is the point - a control layer
#      that is broken at 03:00 on the tenth block should have said so at 09:00
#      when the session opened.
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

# Rows of PENDING_ACTIONS whose recurrence column is >= 3.
# Two parses, in order: a pipe table with a "recurrence" header column, then a
# free-text "recurrence: N" / "recurrence x N" anywhere on the line.
_pending_high_recurrence() {
  local f="$1" hdr_line="" col=0 i n line cell out=""
  [ -r "$f" ] || return 0
  # A header cell is a LABEL: it contains "recurrence" and no digits. That one
  # extra condition is what stops a data row like "| ... recurrence x 5 |" from
  # being mistaken for the header and skipped - which would drop exactly the
  # rows this function exists to find.
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
        *recurrence*) col=$i; hdr="$cand"; break ;;
      esac
    done
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
    if [ "$col" -gt 0 ]; then
      n="$(printf '%s' "$line" | awk -F'|' -v c="$col" '{gsub(/[^0-9]/,"",$c); print $c}' 2>/dev/null)"
    fi
    if [ -z "$n" ]; then
      n="$(printf '%s' "$line" | sed -n 's/.*[Rr]ecurrence[^0-9]\{0,6\}\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    fi
    case "$n" in (*[!0-9]*|"") continue ;; esac
    [ "$n" -ge 3 ] && out="${out}${line}"$'\n'
  done < "$f"
  printf '%s' "$out"
}

# _channel_probe - is the approve-and-continue channel USABLE, right now?
#
# lesson availability-before-security: the control layer is an availability
# surface before it is a security surface, and it cannot repair itself. A
# missing signing key does not surface until an agent is already blocked and
# mid-run, at which point MTTR is however long the human takes to notice. So we
# probe the channel BEFORE it is needed and say so in plain words.
_channel_probe() {
  local key="${ESCALATION_KEY:-secrets/escalation.key}" issues=""
  if [ ! -f "$key" ]; then
    issues="MISSING - no escalation signing key at $key. Every refusal is a dead end until a human runs: .claude/hooks/approve.sh --init-key"
  elif [ ! -r "$key" ]; then
    issues="UNREADABLE - the escalation key at $key cannot be read by the gate; approvals cannot be verified."
  elif [ ! -s "$key" ]; then
    issues="EMPTY - the escalation key at $key is zero bytes; approvals cannot be verified."
  fi
  if [ -z "$issues" ] && [ -r "$RT_SELF_DIR/approve.sh" ] && [ ! -x "$RT_SELF_DIR/approve.sh" ]; then
    issues="NOT EXECUTABLE - approve.sh cannot be run; the human half of the channel is unreachable."
  fi
  if [ -n "$issues" ]; then printf 'FAIL - escalation channel %s' "$issues"; return 0; fi
  printf 'PASS - escalation channel ready (key present, approve.sh runnable)'
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
    printf '| name | status | recurrence |\n'
    printf '|---|---|---|\n'
    printf '| gate-blames-wrong-actor | open | 4 |\n'
    printf '| pager-never-fires | open | 1 |\n'
  } > "$tmp"
  got="$(_pending_high_recurrence "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "1" ] || { echo "FAIL pending table parse: $got"; fail=1; }
  printf 'a note with recurrence: 3 inside\n' > "$tmp"
  got="$(_pending_high_recurrence "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "0" ] || { echo "FAIL pending non-table line must not match: $got"; fail=1; }
  printf '| free form recurrence x 5 |\n' > "$tmp"
  got="$(_pending_high_recurrence "$tmp" | wc -l | tr -d ' ')"
  [ "$got" = "1" ] || { echo "FAIL pending freetext parse: $got"; fail=1; }
  rm -f "$tmp" 2>/dev/null
  got="$(_json_str 'a
b')"
  case "$got" in *'\n'*) : ;; *) echo "FAIL json_str newline: $got"; fail=1 ;; esac
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
  if [ -r "$f" ]; then
    content="$(sed 's/\r$//' "$f" 2>/dev/null)"
    [ -n "$content" ] && { _add "## Live context (${CONTEXT_LIVE:-.pipeline/context-live.md})"; _add ""; _add "$content"; _add ""; }
  fi

  f="$(_abs "${ACTIVE_LESSONS:-.agent-development/ACTIVE-LESSONS.md}")"
  if [ -r "$f" ]; then
    content="$(sed 's/\r$//' "$f" 2>/dev/null | head -n "${CAP_ACTIVE_LESSONS_LINES:-100}")"
    [ -n "$content" ] && { _add "## Active lessons (read at run start, every run)"; _add ""; _add "$content"; _add ""; }
  fi

  f="$(_abs "${PENDING_ACTIONS:-.agent-development/PENDING-HUMAN-ACTIONS.md}")"
  content="$(_pending_high_recurrence "$f")"
  if [ -n "$content" ]; then
    _add "## Pending human actions with recurrence 3 or more"
    _add ""
    _add "A lesson that has recurred three times is a systemic defect, not a note."
    _add ""
    _add "$content"
    _add ""
  fi

  local probe chan
  probe="$(_smoke_probe)"
  chan="$(_channel_probe)"
  _add "## Control-layer self test"
  _add ""
  _add "$probe"
  _add "$chan"
  _add ""
  case "$probe" in
    FAIL*) _add "The control layer is probing FAILED at session start. Gates that fail closed will block, and a block you cannot clear is the expected consequence. Fix this before dispatching anything." ;;
  esac
  case "$chan" in
    FAIL*) _add "The approve-and-continue channel is NOT usable. Refusals that say they are ESCALATABLE are lying: nothing can sign them. File this in PENDING-HUMAN-ACTIONS and raise it on the first Decision Card - do not discover it mid-run against a deadline." ;;
  esac

  if [ -r "$RT_SELF_DIR/pipeline-event.sh" ]; then
    bash "$RT_SELF_DIR/pipeline-event.sh" session_start \
      "milestone=${milestone:-}" "active=$active" "work=$work" "wall=$wall" \
      "smoke=$(case "$probe" in PASS*) echo pass ;; *) echo fail ;; esac)" \
      "channel=$(case "$chan" in PASS*) echo pass ;; *) echo fail ;; esac)" >/dev/null 2>&1 || true
  fi

  _emit
}

main "$@"
