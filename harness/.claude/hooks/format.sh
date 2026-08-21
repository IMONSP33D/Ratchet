#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/format.sh
#
# Contract ............ CONTRACT.md §3 (PostToolUse, matcher Edit|Write)
# Event ............... PostToolUse, matcher: Edit|Write
# Blocking mechanism .. NONE, AND THAT IS LOAD-BEARING. This hook NEVER blocks
#                       and ALWAYS exits 0, on every path including a crash of
#                       the formatter, a missing stack pack, or a payload it
#                       cannot parse. A formatter is a convenience; a
#                       convenience that can stop a run is a defect.
#
# THE .claude/ EXCLUSION - DO NOT REMOVE IT
#   Files under $CLAUDE_DIR are never formatted, no matter what
#   FORMAT_EXTENSIONS says. An escalation approval is a MAC over the sha256 of
#   the RESULTING FILE. A formatter that rewrites that file microseconds after
#   it was written voids the approval it was written under: the bytes the
#   human signed are no longer the bytes on disk, and the next guard check
#   refuses a change that was in fact approved. This is a measured failure,
#   not a hypothetical, and the fix is this five-line carve-out rather than a
#   cleverer hash.
#   The same reasoning applies to $CONTEXT_DIR (human-owned) and $SECRETS_DIR.
#
# STATE FILES: none. This script writes nothing but the formatted file itself,
# and only via the stack pack's FORMAT_CMD.
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
FORMAT_TIMEOUT="${FORMAT_TIMEOUT_SECONDS:-30}"

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
  printf '%s' "${v//$'\r'/}"
}

# The exclusion. Returns 0 when the path must NOT be formatted.
_excluded() {
  local p="$1"
  case "$p" in
    *"/${CLAUDE_DIR:-.claude}/"*|"${CLAUDE_DIR:-.claude}/"*|*/.claude/*|.claude/*) return 0 ;;
    *"/${CONTEXT_DIR:-.context}/"*|"${CONTEXT_DIR:-.context}/"*|*/.context/*|.context/*) return 0 ;;
    *"/${SECRETS_DIR:-secrets}/"*|"${SECRETS_DIR:-secrets}/"*) return 0 ;;
    *"/.git/"*|.git/*) return 0 ;;
  esac
  return 1
}

_ext_wanted() {
  local ext="$1" e
  [ -n "${FORMAT_EXTENSIONS:-}" ] || return 1
  for e in $FORMAT_EXTENSIONS; do
    [ "$ext" = "$e" ] && return 0
  done
  return 1
}

_selftest() {
  local fail=0
  CLAUDE_DIR=".claude"; CONTEXT_DIR=".context"; SECRETS_DIR="secrets"
  _excluded ".claude/hooks/guard.sh" || { echo "FAIL excluded relative .claude"; fail=1; }
  _excluded "/home/x/repo/.claude/settings.json" || { echo "FAIL excluded absolute .claude"; fail=1; }
  _excluded ".context/SPEC.md" || { echo "FAIL excluded .context"; fail=1; }
  _excluded "secrets/escalation.key" || { echo "FAIL excluded secrets"; fail=1; }
  if _excluded "src/app.py"; then echo "FAIL excluded false positive"; fail=1; fi
  if _excluded "tests/test_claude.py"; then echo "FAIL excluded substring false positive"; fail=1; fi
  FORMAT_EXTENSIONS="py pyi"
  _ext_wanted "py" || { echo "FAIL ext_wanted py"; fail=1; }
  if _ext_wanted "md"; then echo "FAIL ext_wanted md"; fail=1; fi
  FORMAT_EXTENSIONS=""
  if _ext_wanted "py"; then echo "FAIL ext_wanted with empty list"; fail=1; fi
  if [ "$fail" -eq 0 ]; then echo "format.sh selftest PASS"; else echo "format.sh selftest FAIL"; fi
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

  local path ext
  path="$(_field tool_input.file_path)"
  [ -n "$path" ] || path="$(_field file_path)"
  [ -n "$path" ] || exit 0

  # Never format the control layer, the human contracts, or secrets.
  _excluded "$path" && exit 0

  [ -f "$path" ] || exit 0
  [ -n "${FORMAT_CMD:-}" ] || exit 0

  ext="${path##*.}"
  case "$path" in *.*) : ;; *) exit 0 ;; esac
  _ext_wanted "$ext" || exit 0

  if command -v timeout >/dev/null 2>&1; then
    timeout "$FORMAT_TIMEOUT" bash -c "$FORMAT_CMD \"\$1\"" _ "$path" >/dev/null 2>&1 || true
  else
    bash -c "$FORMAT_CMD \"\$1\"" _ "$path" >/dev/null 2>&1 || true
  fi
  exit 0
}

main "$@"
