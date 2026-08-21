#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/notify.sh
#
# Contract ............ CONTRACT.md §3 (Notification event), §2.1
#                       (RATCHET_WEBHOOK_URL, https only; PROJECT_NAME)
# Event ............... Notification (no matcher)
# Blocking mechanism .. NONE. Always exits 0. A pager that can stall a run is
#                       worse than no pager.
#
# WHAT IT DOES
#   1. Logs EVERY notification to $PIPELINE_DIR/notifications.log - the full
#      classified record, whether or not it pages. The log is the record; the
#      page is a best-effort courtesy on top of it.
#   2. Pages $RATCHET_WEBHOOK_URL for two classes only:
#        escalation        - a Hard Stop, an escalation request, a decision
#                            card waiting for a human
#        permission-stall  - the session is blocked on a tool-permission
#                            prompt nobody is there to answer
#      Everything else is logged and dropped. A pager that fires on everything
#      is a pager nobody reads.
#   3. https ONLY. An http:// or file:// or otherwise non-https webhook is
#      refused and the refusal is logged. Notifications carry the project
#      name and a message that may quote repo content; that does not travel
#      in clear text.
#   4. Rate limits with a marker file so a stall that re-notifies every few
#      seconds pages once.
#
#   The payload is CONSTRUCTED here, minimally. The raw hook payload is never
#   forwarded: it can contain transcript paths and arbitrary session content,
#   and an outbound webhook is exactly the wrong place to discover that.
#
# NO HARDCODED PROJECT NOUN: the label comes from $PROJECT_NAME (config).
#
# STATE FILES OWNED BY THIS SCRIPT (§0.7)
# ---------------------------------------------------------------------------
# $PIPELINE_DIR/notifications.log
#     One record per notification, appended, never rewritten. Each record is
#     one line, tab-separated, with fields in this fixed order:
#       <ISO-8601 UTC> TAB <class> TAB <paged|nopage:reason> TAB <session-id>
#       TAB <title> TAB <message with newlines collapsed to " / ">
#     class is one of: escalation | permission-stall | info
#
# $PIPELINE_DIR/state/.last-paged
#     One line: decimal epoch seconds of the last successful page attempt.
#     A page is suppressed if it would occur within NOTIFY_PAGE_MIN_SECONDS
#     (default 300) of that timestamp. Deleted by gc-prune.sh start/archive,
#     so a new run always gets its first page.
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
NOTIFY_PAGE_MIN_SECONDS="${NOTIFY_PAGE_MIN_SECONDS:-300}"
NOTIFY_CURL_TIMEOUT="${NOTIFY_CURL_TIMEOUT:-10}"

RT_RAW=""

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

# escalation | permission-stall | info
_classify() {
  local text lc
  text="$1"
  lc="$(printf '%s' "$text" | tr 'A-Z' 'a-z')"
  case "$lc" in
    *escalat*|*"hard stop"*|*"decision card"*|*"wip-escalated"*|*"halt"*)
      printf 'escalation'; return 0 ;;
  esac
  case "$lc" in
    *"needs your permission"*|*"permission to use"*|*"waiting for your input"*|\
    *"is waiting"*|*"approve"*|*"confirm"*|*"idle"*)
      printf 'permission-stall'; return 0 ;;
  esac
  printf 'info'
}

_https_ok() {
  case "${1:-}" in
    https://*) : ;;
    *) return 1 ;;
  esac
  # reject anything with whitespace or a control character - it is going into
  # a curl argument list
  case "$1" in
    *[[:space:]]*) return 1 ;;
  esac
  return 0
}

_rate_ok() { # <marker-file>
  local f="$1" last now
  last="$(_read_first_line "$f" 2>/dev/null)"
  case "$last" in (*[!0-9]*|"") return 0 ;; esac
  now="$(_now)"
  [ "$(( now - last ))" -ge "$NOTIFY_PAGE_MIN_SECONDS" ]
}

_flatten() { printf '%s' "$(printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g')"; }

_selftest() {
  local fail=0 got
  got="$(_classify 'This refusal is ESCALATABLE (id=abc)')"
  [ "$got" = "escalation" ] || { echo "FAIL classify escalation: $got"; fail=1; }
  got="$(_classify 'Claude needs your permission to use Bash')"
  [ "$got" = "permission-stall" ] || { echo "FAIL classify permission: $got"; fail=1; }
  got="$(_classify 'the build finished')"
  [ "$got" = "info" ] || { echo "FAIL classify info: $got"; fail=1; }
  _https_ok "https://example.invalid/hook" || { echo "FAIL https_ok"; fail=1; }
  if _https_ok "http://example.invalid/hook"; then echo "FAIL http accepted"; fail=1; fi
  if _https_ok "file:///etc/passwd"; then echo "FAIL file accepted"; fail=1; fi
  if _https_ok "https://x/ y"; then echo "FAIL whitespace accepted"; fail=1; fi
  if _https_ok ""; then echo "FAIL empty accepted"; fail=1; fi
  got="$(_flatten "$(printf 'a\nb\tc')")"
  [ "$got" = "a b c" ] || { echo "FAIL flatten: [$got]"; fail=1; }
  got="$(_rate_ok /nonexistent/marker; echo $?)"
  [ "$got" = "0" ] || { echo "FAIL rate_ok with no marker: $got"; fail=1; }
  if [ "$fail" -eq 0 ]; then echo "notify.sh selftest PASS"; else echo "notify.sh selftest FAIL"; fi
  return "$fail"
}

main() {
  if [ "${1:-}" = "--selftest" ]; then _selftest; exit "$?"; fi

  [ -t 0 ] || RT_RAW="$(cat 2>/dev/null || true)"
  RT_RAW="${RT_RAW//$'\r'/}"

  _bootstrap || exit 0
  # We consumed stdin before hooklib was sourced, and rt_payload can only read
  # it once. Hand it over so rt_json_field sees the real payload.
  RT_PAYLOAD_READ=1
  RT_PAYLOAD="$RT_RAW"

  local msg title sid class log marker note ms url paid="nopage:not-pageable"
  msg="$(_field message)"
  title="$(_field title)"
  sid="$(_field session_id)"
  [ -n "$msg" ] || msg="(no message field in the Notification payload)"
  class="$(_classify "$title $msg")"

  log="$(_abs "${PIPELINE_DIR:-.pipeline}")/notifications.log"
  marker="$(_abs "${PIPELINE_DIR:-.pipeline}")/state/.last-paged"
  mkdir -p "$(dirname "$log")" "$(dirname "$marker")" 2>/dev/null || true

  url="${RATCHET_WEBHOOK_URL:-}"
  if [ "$class" = "escalation" ] || [ "$class" = "permission-stall" ]; then
    if [ -z "$url" ]; then
      paid="nopage:no-webhook-configured"
    elif ! _https_ok "$url"; then
      paid="nopage:refused-non-https-webhook"
      printf 'ratchet notify: RATCHET_WEBHOOK_URL is not https; refusing to page. Notifications may quote repo content.\n' >&2
    elif ! command -v curl >/dev/null 2>&1; then
      paid="nopage:no-curl"
    elif ! _rate_ok "$marker"; then
      paid="nopage:rate-limited-${NOTIFY_PAGE_MIN_SECONDS}s"
    else
      ms="$(_read_first_line "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")" 2>/dev/null)"
      note="{\"project\":$(_json_str "${PROJECT_NAME:-unknown}"),\"event\":$(_json_str "$class"),\"milestone\":$(_json_str "${ms:-none}"),\"title\":$(_json_str "$title"),\"message\":$(_json_str "$(_flatten "$msg")"),\"ts\":$(_json_str "$(_now_iso)")}"
      printf '%s\n' "$(_now)" > "$marker" 2>/dev/null || true
      if curl -sS -m "$NOTIFY_CURL_TIMEOUT" -X POST \
              -H 'Content-Type: application/json' \
              --data-binary "$note" "$url" >/dev/null 2>&1; then
        paid="paged"
      else
        paid="nopage:webhook-post-failed"
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(_now_iso)" "$class" "$paid" "${sid:-nosession}" "$(_flatten "$title")" "$(_flatten "$msg")" \
    >> "$log" 2>/dev/null || true

  if [ -r "$RT_SELF_DIR/pipeline-event.sh" ]; then
    bash "$RT_SELF_DIR/pipeline-event.sh" notification \
      "class=$class" "paged=$paid" "title=$(_flatten "$title")" >/dev/null 2>&1 || true
  fi

  exit 0
}

main "$@"
