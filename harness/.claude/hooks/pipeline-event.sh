#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/pipeline-event.sh
#
# Contract ............ CONTRACT.md §7.9 (events log), §3 (manual + hook-called)
# Invocation .......... pipeline-event.sh <type> [k=v ...]
# Blocking mechanism .. NONE. This script must NEVER fail its caller.
#                       Every path exits 0, including bootstrap failure.
#                       rt_event() in hooklib.sh calls this script, so this
#                       script must never call rt_event (recursion).
#
# STATE FILE OWNED BY THIS SCRIPT  (§0.7 reader and writer change together)
# ---------------------------------------------------------------------------
# $EVENTS_LOG  (.pipeline/run-events.jsonl)
#     One JSON object per line, appended, never rewritten:
#       {"ts":"<ISO-8601 UTC>","type":"<slug>","run":"<run-token|null>",
#        "milestone":"<id|null>","kv":{...}}
#     ts        : 2026-08-20T04:05:06Z
#     type      : lowercase slug, [a-z0-9_.-], sanitized here
#     run       : contents of $RUN_START (epoch) prefixed with "r", or null
#     milestone : first line of $RUN_ACTIVE, or null
#     kv        : object built from the k=v arguments. The FIRST "=" splits;
#                 everything after it is the value (so k=a=b -> {"k":"a=b"}).
#                 A bare argument with no "=" is recorded as {"<arg>":true}.
#     Values are always JSON strings except the bare-argument true.
#     NOTE (§7.9): metrics use null, not zero, for "not instrumented".
#     A zero in this log always means measured-zero.
#     The log is rotated into .pipeline/archive/ by gc-prune.sh archive.
#
# METRICS ROLL
#     run_metrics.py is rolled at the FOUR run-lifecycle boundaries and only
#     there: run_start, run_reopen, run_archive, run_prune (§5.1).
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

# Guard against a hooklib that emits events on source.
export RATCHET_NO_EVENT=1

RT_BOOT_OK=0
_bootstrap() {
  [ -r "$RT_SELF_DIR/ratchet.config.sh" ] || return 1
  # shellcheck disable=SC1090,SC1091
  . "$RT_SELF_DIR/ratchet.config.sh" >/dev/null 2>&1 || return 1
  local lib=""
  if [ -n "${HOOKS_DIR:-}" ] && [ -r "${HOOKS_DIR}/hooklib.sh" ]; then
    lib="${HOOKS_DIR}/hooklib.sh"
  elif [ -r "$RT_SELF_DIR/hooklib.sh" ]; then
    lib="$RT_SELF_DIR/hooklib.sh"
  fi
  if [ -n "$lib" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$lib" >/dev/null 2>&1 || true
  fi
  if command -v rt_repo_root >/dev/null 2>&1; then
    rt_repo_root >/dev/null 2>&1 || true
  fi
  return 0
}
_bootstrap && RT_BOOT_OK=1

# Absolute path for a possibly repo-relative config value.
_abs() {
  case "$1" in
    /*|[A-Za-z]:[\\/]*) printf '%s' "$1" ;;
    *) printf '%s/%s' "${REPO_ROOT:-$PWD}" "$1" ;;
  esac
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }

_strip_cr() { printf '%s' "${1//$'\r'/}"; }

# JSON string literal from arbitrary text. jq when present, hand-rolled else.
_json_str() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -Rs . 2>/dev/null && return 0
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' 2>/dev/null)"
  printf '"%s"' "$s"
}

_sanitize_type() {
  local t
  t="$(printf '%s' "${1:-}" | LC_ALL=C tr 'A-Z' 'a-z' 2>/dev/null)"
  t="$(printf '%s' "$t" | LC_ALL=C tr -c 'a-z0-9_.-' '_' 2>/dev/null)"
  [ -n "$t" ] || t="unknown"
  printf '%s' "${t:0:64}"
}

# Build the kv object from the remaining arguments.
_kv_object() {
  if [ "$#" -eq 0 ]; then printf '{}'; return 0; fi
  local out="{" first=1 pair k v
  for pair in "$@"; do
    pair="$(_strip_cr "$pair")"
    [ -n "$pair" ] || continue
    case "$pair" in
      *=*) k="${pair%%=*}"; v="${pair#*=}" ;;
      *)   k="$pair"; v="__RT_BARE_TRUE__" ;;
    esac
    k="$(printf '%s' "$k" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_' 2>/dev/null)"
    [ -n "$k" ] || continue
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    if [ "$v" = "__RT_BARE_TRUE__" ]; then
      out="$out$(_json_str "$k"):true"
    else
      out="$out$(_json_str "$k"):$(_json_str "$v")"
    fi
  done
  printf '%s}' "$out"
}

_read_first_line() {
  local f="$1" line=""
  [ -r "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || true
  printf '%s' "${line//$'\r'/}"
}

_roll_metrics() {
  local py="" script=""
  command -v rt_pick_py >/dev/null 2>&1 && py="$(rt_pick_py 2>/dev/null)"
  [ -n "$py" ] || return 0
  script="$(_abs "${HOOKS_DIR:-.claude/hooks}")/run_metrics.py"
  [ -r "$script" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$py" "$script" --write >/dev/null 2>&1 \
      || timeout 60 "$py" "$script" >/dev/null 2>&1 || true
  else
    "$py" "$script" --write >/dev/null 2>&1 \
      || "$py" "$script" >/dev/null 2>&1 || true
  fi
  return 0
}

_selftest() {
  local fail=0 got
  got="$(_sanitize_type 'Run_Start!!')"
  [ "$got" = "run_start__" ] || { echo "FAIL sanitize_type: $got"; fail=1; }
  got="$(_sanitize_type '')"
  [ "$got" = "unknown" ] || { echo "FAIL sanitize_type empty: $got"; fail=1; }
  got="$(_kv_object 'a=1' 'b=x=y' 'flag')"
  case "$got" in
    '{"a":"1","b":"x=y","flag":true}') : ;;
    *) echo "FAIL kv_object: $got"; fail=1 ;;
  esac
  got="$(_kv_object)"
  [ "$got" = "{}" ] || { echo "FAIL kv_object empty: $got"; fail=1; }
  # negative case: a value containing a quote must come back escaped
  got="$(_kv_object 'q=he said "hi"')"
  case "$got" in
    *'\"hi\"'*) : ;;
    *) echo "FAIL kv_object escaping: $got"; fail=1 ;;
  esac
  if [ "$fail" -eq 0 ]; then echo "pipeline-event.sh selftest PASS"; else echo "pipeline-event.sh selftest FAIL"; fi
  return "$fail"
}

main() {
  if [ "${1:-}" = "--selftest" ]; then _selftest; exit "$?"; fi

  local type kv line log run milestone
  type="$(_sanitize_type "${1:-unknown}")"
  [ "$#" -gt 0 ] && shift
  kv="$(_kv_object "$@")"

  if [ "$RT_BOOT_OK" -ne 1 ] || [ -z "${EVENTS_LOG:-}" ]; then
    # Control layer unavailable: say so on stderr, never fail the caller.
    printf 'ratchet: pipeline-event could not load config; event %s dropped\n' \
      "$type" >&2
    exit 0
  fi

  log="$(_abs "$EVENTS_LOG")"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true

  run="null"
  if [ -n "${RUN_START:-}" ] && [ -r "$(_abs "$RUN_START")" ]; then
    local rs; rs="$(_read_first_line "$(_abs "$RUN_START")")"
    [ -n "$rs" ] && run="$(_json_str "r$rs")"
  fi
  milestone="null"
  if [ -n "${RUN_ACTIVE:-}" ] && [ -r "$(_abs "$RUN_ACTIVE")" ]; then
    local ms; ms="$(_read_first_line "$(_abs "$RUN_ACTIVE")")"
    [ -n "$ms" ] && milestone="$(_json_str "$ms")"
  fi

  line="{\"ts\":$(_json_str "$(_now_iso)"),\"type\":$(_json_str "$type"),\"run\":$run,\"milestone\":$milestone,\"kv\":$kv}"
  printf '%s\n' "$line" >> "$log" 2>/dev/null || true

  case "$type" in
    run_start|run_reopen|run_archive|run_prune) _roll_metrics ;;
  esac

  exit 0
}

main "$@"
