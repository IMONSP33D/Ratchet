#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/gc-prune.sh
#
# Contract ............ CONTRACT.md §5.1 (run lifecycle - ONE origin),
#                       §5.3 (WORK budget), §5.5 (approvals die at gate
#                       closure), §7.9 (events log rotation)
# Invocation .......... gc-prune.sh start <milestone>
#                       gc-prune.sh reopen [<milestone>]
#                       gc-prune.sh archive <milestone>
#                       gc-prune.sh prune
#                       gc-prune.sh --selftest
# Blocking mechanism .. NONE. Exit 0 on success, 1 on usage/IO/precondition
#                       failure. It refuses rather than guesses.
#
# THIS SCRIPT OWNS ALL FOUR RUN-LIFECYCLE TRANSITIONS AND NOTHING ELSE WRITES
# $RUN_ACTIVE, $RUN_START, $RUN_IDLE OR $READY_TO_SHIP.
#   Forget `start` and the run is ungated: with no run active every scope check
#   and the Stop gate's definition-of-done checks are inert, by design. Leave
#   the marker behind after a milestone closes and the NEXT session is gated by
#   a dead manifest, which is the same defect wearing the opposite sign. One
#   origin for both transitions is what makes either statement checkable.
#
#   RUN_START IS WRITTEN ONCE, BY `start`. `reopen` preserves it verbatim.
#   No script may edit RUN_START to clear a budget halt - rewinding the clock
#   would make the work budget unfalsifiable, which is the one thing it exists
#   to prevent. If a run genuinely needs more budget that is a human decision
#   recorded as one, not a file edit.
#
# STATE FILES OWNED BY THIS SCRIPT (§0.7)
# ---------------------------------------------------------------------------
# $RUN_ACTIVE   (.pipeline/run-active)   one line: the milestone id. Presence
#                                        of the file is the run marker.
# $RUN_START    (.pipeline/run-start)    one line: decimal epoch seconds.
# $RUN_IDLE     (.pipeline/run-idle)     one line: decimal seconds of folded
#                                        idle. `start` zeroes it; hooklib's
#                                        rt_touch_seen adds gaps to it;
#                                        `reopen` adds the archived-to-reopened
#                                        gap to it so the pause is not counted
#                                        as work.
# $RUN_LAST_SEEN(.pipeline/run-last-seen) one line: decimal epoch seconds.
# $READY_TO_SHIP(.pipeline/ready-to-ship) presence selects the ship tier;
#                                        removed by `start` and `archive`.
#
# $PIPELINE_DIR/archive/<milestone>-<epoch>/     written by `archive`
#     manifest/     plan-files.txt, manifest-amendments.txt
#     journal/      run-journal.md
#     findings.md, verify-last.json, red-baseline.txt, ship-consent.json,
#     run-events.jsonl        (MOVED, not copied - the live log restarts empty)
#     checkpoints/  the whole checkpoints directory
#     state/        run-active, run-start, run-idle  (so `reopen` can restore
#                   elapsed work without recomputing it)
#     ARCHIVE-INFO  key: value lines: milestone, archived_at, epoch, head,
#                   branch, work_seconds, wall_seconds
#
# WHAT `prune` MAY TOUCH
#     Scratch hygiene only: per-session gate counters, dispatch records that
#     are not `current`, red-phase copies, and stray .tmp/.out files under
#     $PIPELINE_DIR. It never touches RUN_*, findings, journal, checkpoints,
#     escalations or anything under .agent-development (tracked, never pruned).
# =============================================================================

set -uo pipefail

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
PRUNE_STATE_DAYS="${PRUNE_STATE_DAYS:-2}"
PRUNE_DISPATCH_DAYS="${PRUNE_DISPATCH_DAYS:-7}"

_bootstrap() {
  [ -r "$RT_SELF_DIR/ratchet.config.sh" ] || return 1
  # shellcheck disable=SC1090,SC1091
  . "$RT_SELF_DIR/ratchet.config.sh" || return 1
  local lib=""
  if [ -n "${HOOKS_DIR:-}" ] && [ -r "${HOOKS_DIR}/hooklib.sh" ]; then
    lib="${HOOKS_DIR}/hooklib.sh"
  elif [ -r "$RT_SELF_DIR/hooklib.sh" ]; then
    lib="$RT_SELF_DIR/hooklib.sh"
  fi
  if [ -n "$lib" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$lib" || return 1
  fi
  command -v rt_repo_root >/dev/null 2>&1 && { rt_repo_root >/dev/null 2>&1 || true; }
  if [ -r "$RT_SELF_DIR/escalation-lib.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$RT_SELF_DIR/escalation-lib.sh" >/dev/null 2>&1 || true
  fi
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
_read_int() { # <file> <default>
  local v; v="$(_read_first_line "$1" 2>/dev/null)"
  case "$v" in (*[!0-9]*|"") v="${2:-0}" ;; esac
  printf '%s' "$v"
}
_event() {
  local t="$1"; shift
  if [ -r "$RT_SELF_DIR/pipeline-event.sh" ]; then
    bash "$RT_SELF_DIR/pipeline-event.sh" "$t" "$@" >/dev/null 2>&1 || true
  fi
  return 0
}

# Milestone ids become a directory component: keep them boring.
_ms_valid() {
  case "${1:-}" in
    "" ) return 1 ;;
    *[/\\]* ) return 1 ;;
    .* ) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

_P()  { printf '%s' "$(_abs "${PIPELINE_DIR:-.pipeline}")"; }
_f_active()   { printf '%s' "$(_abs "${RUN_ACTIVE:-.pipeline/run-active}")"; }
_f_start()    { printf '%s' "$(_abs "${RUN_START:-.pipeline/run-start}")"; }
_f_idle()     { printf '%s' "$(_abs "${RUN_IDLE:-.pipeline/run-idle}")"; }
_f_seen()     { printf '%s' "$(_abs "${RUN_LAST_SEEN:-.pipeline/run-last-seen}")"; }
_f_ready()    { printf '%s' "$(_abs "${READY_TO_SHIP:-.pipeline/ready-to-ship}")"; }
_f_events()   { printf '%s' "$(_abs "${EVENTS_LOG:-.pipeline/run-events.jsonl}")"; }

_expire_approvals() {
  local dir n=0 f
  if command -v esc_expire_all >/dev/null 2>&1; then
    esc_expire_all >/dev/null 2>&1 && { printf 'escalation approvals expired via esc_expire_all\n'; return 0; }
  fi
  # Fallback: remove every unconsumed approval artifact and record the sweep in
  # the ledger. Approvals are run-bound; nothing survives gate closure. If this
  # cannot be done the caller is told, because a surviving approval is exactly
  # the thing that must not outlive its run silently.
  dir="$(_abs "${ESCALATIONS_DIR:-.pipeline/escalations}")"
  if [ -d "$dir" ]; then
    for f in "$dir"/approved/* "$dir"/*.approval "$dir"/*.approved "$dir"/disclosures/*; do
      [ -e "$f" ] || continue
      rm -f "$f" 2>/dev/null && n=$((n+1))
    done
  fi
  local ledger; ledger="$(_abs "${ESCALATION_LEDGER:-.pipeline/escalations/ledger.jsonl}")"
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  printf '{"ts":"%s","event":"expire_all","reason":"gate closure","removed":%s,"by":"gc-prune.sh"}\n' \
    "$(_now_iso)" "$n" >> "$ledger" 2>/dev/null || true
  printf 'escalation approvals expired: %s artifact(s) removed, sweep recorded in %s\n' "$n" "$ledger"
  return 0
}

# --- transitions ----------------------------------------------------------- #
_start() {
  local ms="$1" p
  _ms_valid "$ms" || { printf 'gc-prune: invalid milestone id "%s" (^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$)\n' "$ms" >&2; return 1; }
  p="$(_P)"; mkdir -p "$p" "$p/state" "$p/dispatch" 2>/dev/null || true
  if [ -e "$(_f_active)" ]; then
    local cur; cur="$(_read_first_line "$(_f_active)")"
    printf 'gc-prune: a run is already active (%s). Archive it first, or use `reopen`.\n' "${cur:-unknown}" >&2
    return 1
  fi
  printf '%s\n' "$ms"      > "$(_f_active)" || return 1
  printf '%s\n' "$(_now)"  > "$(_f_start)"  || return 1
  printf '0\n'             > "$(_f_idle)"   || return 1
  printf '%s\n' "$(_now)"  > "$(_f_seen)"   || return 1
  rm -f "$(_f_ready)" 2>/dev/null || true
  rm -f "$p"/state/* 2>/dev/null || true
  printf 'gc-prune: run %s started at %s. Gates are live: scope checks and the definition of done now apply.\n' \
    "$ms" "$(_now_iso)"
  _event run_start "milestone=$ms"
  return 0
}

_reopen() {
  local want="${1:-}" p adir found="" ms start idle gap now
  p="$(_P)"; adir="$p/archive"
  if [ -e "$(_f_active)" ]; then
    printf 'gc-prune: a run is already active (%s); nothing to reopen.\n' "$(_read_first_line "$(_f_active)")" >&2
    return 1
  fi
  [ -d "$adir" ] || { printf 'gc-prune: no archive directory at %s\n' "$adir" >&2; return 1; }
  # newest archive first; optionally filtered by milestone
  local d
  for d in $(ls -1t "$adir" 2>/dev/null); do
    [ -d "$adir/$d" ] || continue
    [ -r "$adir/$d/state/run-active" ] || continue
    if [ -n "$want" ]; then
      case "$d" in "$want"-*) : ;; *) continue ;; esac
    fi
    found="$adir/$d"; break
  done
  [ -n "$found" ] || { printf 'gc-prune: no archived run%s found under %s\n' "${want:+ for $want}" "$adir" >&2; return 1; }

  ms="$(_read_first_line "$found/state/run-active")"
  start="$(_read_int "$found/state/run-start" "$(_now)")"
  idle="$(_read_int "$found/state/run-idle" 0)"
  now="$(_now)"
  # The archived-to-reopened pause is idle, not work. Elapsed work is
  # PRESERVED: RUN_START is restored verbatim and never rewound.
  local arch_epoch; arch_epoch="$(_read_int "$found/ARCHIVE-EPOCH" "$now")"
  gap=$(( now - arch_epoch )); [ "$gap" -gt 0 ] || gap=0
  idle=$(( idle + gap ))

  mkdir -p "$p" "$p/state" 2>/dev/null || true
  printf '%s\n' "$ms"    > "$(_f_active)" || return 1
  printf '%s\n' "$start" > "$(_f_start)"  || return 1
  printf '%s\n' "$idle"  > "$(_f_idle)"   || return 1
  printf '%s\n' "$now"   > "$(_f_seen)"   || return 1

  # Restore the manifest and journal only if the live copies are absent, so a
  # reopen never overwrites work done since.
  local mf
  for mf in "${PLAN_FILES:-.pipeline/plan-files.txt}" "${AMENDMENTS:-.pipeline/manifest-amendments.txt}"; do
    [ -e "$(_abs "$mf")" ] && continue
    [ -r "$found/manifest/$(basename "$mf")" ] && cp -f "$found/manifest/$(basename "$mf")" "$(_abs "$mf")" 2>/dev/null || true
  done
  if [ ! -e "$(_abs "${RUN_JOURNAL:-.pipeline/run-journal.md}")" ] \
     && [ -r "$found/journal/$(basename "${RUN_JOURNAL:-run-journal.md}")" ]; then
    cp -f "$found/journal/$(basename "${RUN_JOURNAL:-run-journal.md}")" \
          "$(_abs "${RUN_JOURNAL:-.pipeline/run-journal.md}")" 2>/dev/null || true
  fi

  printf 'gc-prune: run %s reopened from %s. Elapsed work preserved (start %s, idle %s incl. a %ss pause).\n' \
    "$ms" "$found" "$start" "$idle" "$gap"
  printf 'gc-prune: escalation approvals were expired at archive and are NOT restored.\n'
  _event run_reopen "milestone=$ms" "start=$start" "idle=$idle" "pause=$gap" "from=$found"
  return 0
}

_archive() {
  local ms="$1" p adir dest now head branch work=-1 wall=-1
  _ms_valid "$ms" || { printf 'gc-prune: invalid milestone id "%s"\n' "$ms" >&2; return 1; }
  p="$(_P)"; now="$(_now)"
  adir="$p/archive"; dest="$adir/$ms-$now"
  mkdir -p "$dest/manifest" "$dest/journal" "$dest/state" 2>/dev/null \
    || { printf 'gc-prune: cannot create %s\n' "$dest" >&2; return 1; }

  head="NO-HEAD"; branch="UNKNOWN"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    head="$(git rev-parse HEAD 2>/dev/null)"; [ -n "$head" ] || head="NO-HEAD"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; [ -n "$branch" ] || branch="DETACHED"
  fi
  command -v rt_work_seconds >/dev/null 2>&1 && work="$(rt_work_seconds 2>/dev/null)"
  command -v rt_wall_seconds >/dev/null 2>&1 && wall="$(rt_wall_seconds 2>/dev/null)"

  # manifest + journal
  local f
  for f in "${PLAN_FILES:-.pipeline/plan-files.txt}" "${AMENDMENTS:-.pipeline/manifest-amendments.txt}"; do
    [ -r "$(_abs "$f")" ] && mv -f "$(_abs "$f")" "$dest/manifest/$(basename "$f")" 2>/dev/null || true
  done
  f="${RUN_JOURNAL:-.pipeline/run-journal.md}"
  [ -r "$(_abs "$f")" ] && mv -f "$(_abs "$f")" "$dest/journal/$(basename "$f")" 2>/dev/null || true

  # run artefacts worth keeping next to the manifest
  for f in "${FINDINGS:-.pipeline/findings.md}" "${VERIFY_LAST:-.pipeline/verify-last.json}" \
           "${RED_BASELINE:-.pipeline/red-baseline.txt}" "${SHIP_CONSENT:-.pipeline/ship-consent.json}" \
           "${RECAP:-.pipeline/recap.md}" "${CONTEXT_LIVE:-.pipeline/context-live.md}"; do
    [ -r "$(_abs "$f")" ] && cp -f "$(_abs "$f")" "$dest/$(basename "$f")" 2>/dev/null || true
  done
  [ -d "$(_abs "${CHECKPOINTS_DIR:-.pipeline/checkpoints}")" ] \
    && cp -R "$(_abs "${CHECKPOINTS_DIR:-.pipeline/checkpoints}")" "$dest/checkpoints" 2>/dev/null || true

  # run state, so reopen can restore elapsed work without recomputing it
  for f in "$(_f_active)" "$(_f_start)" "$(_f_idle)"; do
    [ -r "$f" ] && cp -f "$f" "$dest/state/$(basename "$f")" 2>/dev/null || true
  done
  printf '%s\n' "$now" > "$dest/ARCHIVE-EPOCH" 2>/dev/null || true

  # events log ROTATES: nothing outlives its run silently.
  if [ -r "$(_f_events)" ]; then
    mv -f "$(_f_events)" "$dest/$(basename "$(_f_events)")" 2>/dev/null || true
    : > "$(_f_events)" 2>/dev/null || true
  fi

  local esc_msg; esc_msg="$(_expire_approvals)"

  # Refusal records ROTATE into the archive alongside the events log. A refusal
  # record IS evidence -- what was refused, and what bytes an approval would have
  # been bound to -- so it is moved, never deleted. But it is evidence OF THIS
  # RUN, and a live directory that only ever grows is the artifacts-outlive-their-run
  # lesson wearing a different hat: at ~30 unique refusals a run it reaches tens of
  # thousands of 67-byte files, which is inode and listing cost for nothing.
  # The LEDGER stays live and is never rotated: it is the single-use replay
  # defence, and it is append-only by design.
  local edir eledger emoved
  edir="$(_abs "${ESCALATIONS_DIR:-.pipeline/escalations}")"
  eledger="$(_abs "${ESCALATION_LEDGER:-.pipeline/escalations/ledger.jsonl}")"
  if [ -d "$edir" ]; then
    emoved=0
    mkdir -p "$dest/escalations" 2>/dev/null || true
    for f in "$edir"/*; do
      [ -e "$f" ] || continue
      [ "$f" = "$eledger" ] && continue
      case "$(basename "$f")" in
        ledger.jsonl|postcondition-*) continue ;;
      esac
      mv -f "$f" "$dest/escalations/" 2>/dev/null && emoved=$((emoved+1))
    done
    [ "$emoved" -gt 0 ] && esc_msg="$esc_msg; $emoved record(s) rotated to archive"
    rmdir "$dest/escalations" 2>/dev/null || true
  fi

  {
    printf 'milestone: %s\n' "$ms"
    printf 'archived_at: %s\n' "$(_now_iso)"
    printf 'epoch: %s\n' "$now"
    printf 'head: %s\n' "$head"
    printf 'branch: %s\n' "$branch"
    printf 'work_seconds: %s\n' "$work"
    printf 'wall_seconds: %s\n' "$wall"
    printf 'escalations: %s\n' "$esc_msg"
  } > "$dest/ARCHIVE-INFO" 2>/dev/null || true

  # clear the run markers LAST: until this point a crash leaves the run active,
  # which is the safe direction to fail.
  rm -f "$(_f_active)" "$(_f_ready)" 2>/dev/null || true
  rm -f "$p"/state/* 2>/dev/null || true
  rm -f "$p"/dispatch/current 2>/dev/null || true

  printf 'gc-prune: milestone %s archived to %s\n' "$ms" "$dest"
  printf 'gc-prune: %s\n' "$esc_msg"
  printf 'gc-prune: run marker cleared - scope checks and the definition of done are now INERT.\n'
  _event run_archive "milestone=$ms" "dest=$dest" "head=$head" "work=$work" "wall=$wall"
  return 0
}

_prune() {
  local p n=0 f cur
  p="$(_P)"
  [ -d "$p" ] || { printf 'gc-prune: nothing to prune (%s absent)\n' "$p"; return 0; }
  cur="$(_read_first_line "$p/dispatch/current" 2>/dev/null)"

  if [ -d "$p/state" ] && command -v find >/dev/null 2>&1; then
    n=$(( n + $(find "$p/state" -type f -mtime "+${PRUNE_STATE_DAYS}" 2>/dev/null | wc -l | tr -d ' ') ))
    find "$p/state" -type f -mtime "+${PRUNE_STATE_DAYS}" -exec rm -f {} \; 2>/dev/null || true
  fi

  if [ -d "$p/dispatch" ] && command -v find >/dev/null 2>&1; then
    for f in $(find "$p/dispatch" -type f -mtime "+${PRUNE_DISPATCH_DAYS}" 2>/dev/null); do
      case "$(basename "$f")" in
        current) continue ;;
        "$cur".*) continue ;;
      esac
      rm -f "$f" 2>/dev/null && n=$((n+1))
    done
  fi

  for f in "$p"/.*-out.* "$p"/*.tmp.* "$p"/.py-interp.tmp*; do
    [ -e "$f" ] || continue
    rm -f "$f" 2>/dev/null && n=$((n+1))
  done

  if [ -d "$p/red" ] && command -v find >/dev/null 2>&1; then
    for f in $(find "$p/red" -type f -mtime "+${PRUNE_DISPATCH_DAYS}" 2>/dev/null); do
      rm -f "$f" 2>/dev/null && n=$((n+1))
    done
  fi

  printf 'gc-prune: pruned %s scratch file(s) under %s. Run markers, findings, journal, checkpoints and the escalation ledger untouched (refusal records rotate at archive, not here).\n' "$n" "$p"
  _event run_prune "removed=$n"
  return 0
}

_selftest() {
  local fail=0
  _ms_valid "M1" || { echo "FAIL ms_valid M1"; fail=1; }
  _ms_valid "M12.rev-2" || { echo "FAIL ms_valid dotted"; fail=1; }
  if _ms_valid "../etc"; then echo "FAIL ms_valid traversal"; fail=1; fi
  if _ms_valid "a/b"; then echo "FAIL ms_valid slash"; fail=1; fi
  if _ms_valid ""; then echo "FAIL ms_valid empty"; fail=1; fi
  local got
  got="$(_read_int /nonexistent/x 7)"; [ "$got" = "7" ] || { echo "FAIL read_int default: $got"; fail=1; }
  if [ "$fail" -eq 0 ]; then echo "gc-prune.sh selftest PASS"; else echo "gc-prune.sh selftest FAIL"; fi
  return "$fail"
}

_usage() {
  cat <<'EOF'
usage: gc-prune.sh start <milestone>   arm a run: run-active, run-start, run-idle=0
       gc-prune.sh reopen [<milestone>] re-arm the newest archived run WITHOUT
                                        resetting elapsed work
       gc-prune.sh archive <milestone>  archive manifest+journal, clear the run
                                        marker and ready-to-ship, expire every
                                        escalation approval, rotate the events log
       gc-prune.sh prune                scratch hygiene only
       gc-prune.sh --selftest

This script owns all four run-lifecycle transitions. Nothing else writes
run-active, run-start, run-idle or ready-to-ship. RUN_START is never rewound.
EOF
}

main() {
  case "${1:-}" in
    --selftest) _selftest; exit "$?" ;;
    -h|--help|"") _usage; [ -z "${1:-}" ] && exit 1; exit 0 ;;
  esac
  if ! _bootstrap; then
    printf 'gc-prune: the control layer could not be loaded from %s\n' "$RT_SELF_DIR" >&2
    exit 1
  fi
  local cmd="$1"; shift
  case "$cmd" in
    start)   [ "$#" -ge 1 ] || { _usage; exit 1; }; _start "$1" ;;
    reopen)  _reopen "${1:-}" ;;
    archive) [ "$#" -ge 1 ] || { _usage; exit 1; }; _archive "$1" ;;
    prune)   _prune ;;
    *) printf 'gc-prune: unknown subcommand "%s"\n' "$cmd" >&2; _usage; exit 1 ;;
  esac
  exit "$?"
}

main "$@"
