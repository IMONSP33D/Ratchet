#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/escalate.sh
#
# HUMANS: you do not run this. The AGENT runs it. Your half is approve.sh.
#
# Contract ............ CONTRACT.md §5.5 (escalation), §3 (manual, agent-
#                       invocable, allow-listed)
# Invocation .......... escalate.sh request <id> "<why this specific call>"
#                       escalate.sh status <id> | list | postcondition-clear
#                       escalate.sh postcondition-status | --selftest
# Blocking mechanism .. NONE. This script asks; it never permits anything.
#                       Exit 0 = a request was filed. Exit non-zero = refused.
#
# WHAT THIS SCRIPT CAN AND CANNOT DO
#   It can: file a request against a refusal that already happened, attach the
#           agent's justification as a free-text sidecar, and print the exact
#           one-line command a human must run in their own terminal.
#   It cannot: approve anything. It never touches $ESCALATION_KEY, and it would
#           be useless if it did -- the key is denied to the agent at the
#           settings layer and at the guard layer, and that deny is itself
#           never-escalatable. Filing a request is not consent; the human's
#           signature is, and the human produces it somewhere this process
#           cannot reach.
#
# THE TWO CLASSES, AND WHY THE MESSAGE MATTERS
#   A guard refusal either says "This refusal is ESCALATABLE (id=...)" or it
#   does not. If it does not, no approval exists that lifts it -- and this
#   script refuses to file the request rather than letting the agent spend a
#   human round-trip discovering that. Unknown rule ids are refused for the
#   same reason: the harness fails closed on ignorance (escalation-lib.sh I3).
#
# STATE FILES WRITTEN BY THIS SCRIPT (§0.7)
#   $ESCALATIONS_DIR/<id>.why      free text, the agent's justification. Never
#                                  parsed by anything, never inside the JSON.
#   $ESCALATIONS_DIR/<id>.request  flat json marker (format documented in
#                                  escalation-lib.sh's header block).
# =============================================================================

set -uo pipefail

ESC_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

# shellcheck disable=SC1090,SC1091
if [ -r "$ESC_SH_DIR/escalation-lib.sh" ]; then
  . "$ESC_SH_DIR/escalation-lib.sh"
else
  printf 'escalate: cannot load escalation-lib.sh from %s\n' "$ESC_SH_DIR" >&2
  exit 1
fi

esc_sh__usage() {
  cat <<'USAGE'
escalate.sh -- file an escalation request against a refusal that already happened.

  escalate.sh request <id> "<why this specific call>"
      Files a request for the refusal recorded under <id>. The id comes from
      the guard's refusal message: "This refusal is ESCALATABLE (id=esc-...)".
      Prints the exact command the HUMAN must run in their own terminal.

  escalate.sh status <id>          show a refusal record and whether it is approved
  escalate.sh list                 list this run's refusals and their state
  escalate.sh show <id>            print the exact refused bytes
  escalate.sh postcondition-status is a control-layer postcondition pending?
  escalate.sh postcondition-clear  run the control-layer selftest and clear it
  escalate.sh --selftest

After filing a request you must still raise a Decision Card. A request nobody
was asked about is a request nobody will answer -- and you never proceed on
silence.
USAGE
}

esc_sh__id_valid() { printf '%s' "${1:-}" | grep -Eq '^esc-[0-9a-f]{16}$'; }

esc_sh__require_record() {  # <id> -> 0 and echoes the record path
  local id="$1" dir f
  dir="$(esc__dir)"
  f="$dir/$id.json"
  if [ ! -r "$f" ]; then
    printf 'escalate: no refusal is recorded under id %s.\n' "$id" >&2
    printf '  An id is produced BY THE REFUSAL. You cannot invent one, and you cannot file a\n' >&2
    printf '  request for a call that was never refused. Re-issue the call, copy the id out of\n' >&2
    printf '  the refusal message, and try again.\n' >&2
    return 1
  fi
  printf '%s' "$f"
}

esc_sh__request() {
  local id="${1:-}" why="${2:-}"
  if ! esc_sh__id_valid "$id"; then
    printf 'escalate: malformed id %s (expected esc-<16 hex>).\n' "$id" >&2
    return 2
  fi
  if [ -z "$why" ]; then
    printf 'escalate: a justification is required.\n' >&2
    printf '  Say why THIS SPECIFIC CALL is justified -- not why the rule is annoying.\n' >&2
    printf '  usage: escalate.sh request %s "<why this specific call>"\n' "$id" >&2
    return 2
  fi

  local rec; rec="$(esc_sh__require_record "$id")" || return 1

  local rule tool class tkind tpath
  rule="$(esc_json_get "$rec" rule)"
  tool="$(esc_json_get "$rec" tool)"
  tkind="$(esc_json_get "$rec" target_kind)"
  tpath="$(esc_json_get "$rec" target_path)"
  class="$(esc_classify "$rule" 2>/dev/null)"

  # --- the wall ------------------------------------------------------------
  if [ "$class" = "unknown" ]; then
    printf 'escalate: REFUSED. Rule "%s" is not in the harness rule vocabulary.\n' "$rule" >&2
    printf '  An unclassified rule is treated as never-escalatable (fail closed). This is a\n' >&2
    printf '  control-layer defect, not a decision you can route around: raise it as a finding\n' >&2
    printf '  so the rule is classified in escalation-lib.sh.\n' >&2
    esc__ledger_append "request_refused_unknown" "$id" "$rule" "$tool" "-" "-" || true
    return 3
  fi
  if [ "$class" = "never" ]; then
    printf 'escalate: REFUSED. Rule "%s" is NEVER-ESCALATABLE.\n' "$rule" >&2
    printf '  No approval exists that lifts it -- not the human'"'"'s, not one signed by mistake.\n' >&2
    printf '  approve.sh will refuse this id, and so will the guard, even with a valid signature.\n' >&2
    printf '\n' >&2
    printf '  This is the Hard Stop flow, not the escalation flow:\n' >&2
    printf '    1. write the Decision Card into the escalation report;\n' >&2
    printf '    2. commit WIP on the agent branch as WIP-ESCALATED;\n' >&2
    printf '    3. stop cleanly. Do not widen scope, weaken a check, or look for another route.\n' >&2
    esc__ledger_append "request_refused_never" "$id" "$rule" "$tool" "-" "-" || true
    return 4
  fi

  # --- byte-exactness must be derivable ------------------------------------
  if [ "$tkind" = "ambiguous" ]; then
    printf 'escalate: REFUSED. This Edit has no single derivable result.\n' >&2
    printf '  old_string occurs more than once in %s and replace_all is not set, so there is no\n' "$tpath" >&2
    printf '  one resulting file for a human to sign. An approval that cannot name the bytes it\n' >&2
    printf '  authorises is not byte-exact.\n' >&2
    printf '  Re-issue as Write with the COMPLETE file content, then escalate that call.\n' >&2
    esc__ledger_append "request_refused_ambiguous" "$id" "$rule" "$tool" "-" "-" || true
    return 5
  fi
  case "$tkind" in
    unsupported|error|underivable)
      printf 'escalate: REFUSED. The resulting bytes of this call could not be derived (%s).\n' "$tkind" >&2
      printf '  Re-issue as Write with the complete file content.\n' >&2
      esc__ledger_append "request_refused_underivable" "$id" "$rule" "$tool" "-" "-" || true
      return 5 ;;
  esac

  # --- run binding ---------------------------------------------------------
  local rtok rec_tok
  rtok="$(esc_run_token 2>/dev/null)"
  rec_tok="$(esc_json_get "$rec" run_token 2>/dev/null)"
  if [ -n "$rec_tok" ] && [ "$rec_tok" != "$rtok" ]; then
    printf 'escalate: REFUSED. That refusal belongs to a different run.\n' >&2
    printf '  Approvals die at gate closure. Re-issue the call in this run to get a fresh id.\n' >&2
    return 6
  fi

  # --- file it -------------------------------------------------------------
  esc__ensure_dir || { printf 'escalate: cannot create %s\n' "$(esc__dir)" >&2; return 1; }
  local dir; dir="$(esc__dir)"
  # FREE TEXT LIVES HERE AND ONLY HERE. The record JSON is read by a
  # constrained grep reader, so prose must never enter it.
  printf '%s\n' "$why" > "$dir/$id.why" || return 1
  local whysha; whysha="$(esc__sha256_file "$dir/$id.why")"

  esc__json_write "$dir/$id.request" \
    version esc/1 \
    id "$id" \
    rule "$rule" \
    tool "$tool" \
    requested_at "$(esc__now)" \
    why_sha "${whysha:-none}" || return 1
  esc__ledger_append "requested" "$id" "$rule" "$tool" "$(esc_json_get "$rec" target_sha)" "-" || true

  # --- what the agent must show the human ----------------------------------
  printf 'Escalation request filed.\n\n'
  printf '  id        %s\n' "$id"
  printf '  rule      %s (confirmable in %s mode)\n' "$rule" "$(esc_mode)"
  printf '  tool      %s\n' "$tool"
  [ "$tpath" != "-" ] && printf '  target    %s\n' "$tpath"
  printf '  bytes     %s bytes, sha %s\n' "$(esc_json_get "$rec" payload_len)" "$(esc_json_get "$rec" payload_sha)"
  printf '\nTHE HUMAN RUNS THIS, IN THEIR OWN TERMINAL:\n\n'
  printf '  bash %s/approve.sh %s\n' "$HOOKS_DIR" "$id"
  printf '\n'
  printf 'It will show them the exact refused bytes, make them retype the id, and sign a\n'
  printf 'single-use approval that expires in %s seconds and dies at gate closure.\n' "${ESCALATION_TTL_SECONDS:-1800}"
  printf '\nYOU ARE NOT DONE. Raise the Decision Card now:\n'
  printf '  - Situation / Why this reached you / Blast radius, in one short paragraph;\n'
  printf '  - a selector with your recommendation first and a real alternative;\n'
  printf '  - the approve.sh line above inside the approving option'"'"'s description;\n'
  printf '  - prior rulings pasted verbatim if this touches a named constant, a refusal rule\n'
  printf '    or a security control.\n'
  printf 'Then re-issue the IDENTICAL call. One byte different is a different call.\n'
  printf 'Never proceed on silence: no answer is no.\n'
  return 0
}

esc_sh__status() {
  local id="${1:-}" rec dir
  esc_sh__id_valid "$id" || { printf 'escalate: malformed id %s\n' "$id" >&2; return 2; }
  rec="$(esc_sh__require_record "$id")" || return 1
  dir="$(esc__dir)"
  printf 'id          %s\n' "$id"
  printf 'rule        %s\n' "$(esc_json_get "$rec" rule)"
  printf 'class       %s\n' "$(esc_classify "$(esc_json_get "$rec" rule)" 2>/dev/null)"
  printf 'tool        %s\n' "$(esc_json_get "$rec" tool)"
  printf 'target      %s (%s)\n' "$(esc_json_get "$rec" target_path)" "$(esc_json_get "$rec" target_kind)"
  printf 'target_sha  %s\n' "$(esc_json_get "$rec" target_sha)"
  printf 'run_token   %s (current %s)\n' "$(esc_json_get "$rec" run_token)" "$(esc_run_token)"
  if [ -r "$dir/$id.request" ]; then
    printf 'requested   yes, at %s\n' "$(esc_json_get "$dir/$id.request" requested_at)"
  else
    printf 'requested   no\n'
  fi
  if [ -r "$dir/$id.approval" ]; then
    printf 'approval    PRESENT (expiry %s, now %s)\n' "$(esc_json_get "$dir/$id.approval" expiry)" "$(esc__now)"
  elif [ -r "$dir/$id.approval.consumed" ]; then
    printf 'approval    CONSUMED (single-use; ask again if you need it again)\n'
  else
    printf 'approval    none\n'
  fi
  if [ -r "$dir/$id.why" ]; then
    printf 'why         %s\n' "$(head -c 400 "$dir/$id.why" 2>/dev/null | tr '\n' ' ')"
  fi
  return 0
}

esc_sh__list() {
  local dir f id n=0
  dir="$(esc__dir)"
  [ -d "$dir" ] || { printf 'no escalations recorded.\n'; return 0; }
  printf '%-22s %-28s %-12s %s\n' "id" "rule" "class" "state"
  for f in "$dir"/esc-*.json; do
    [ -r "$f" ] || continue
    case "$f" in *.request|*.approval*) continue ;; esac
    id="$(esc_json_get "$f" id 2>/dev/null)" || continue
    local rule state
    rule="$(esc_json_get "$f" rule)"
    if   [ -r "$dir/$id.approval" ];          then state="APPROVED (unconsumed)"
    elif [ -r "$dir/$id.approval.consumed" ]; then state="consumed"
    elif [ -r "$dir/$id.request" ];           then state="requested, awaiting human"
    else state="refused, not requested"; fi
    printf '%-22s %-28s %-12s %s\n' "$id" "$rule" "$(esc_classify "$rule" 2>/dev/null)" "$state"
    n=$(( n + 1 ))
  done
  [ "$n" -eq 0 ] && printf '(none)\n'
  return 0
}

esc_sh__show() {
  local id="${1:-}" dir
  esc_sh__id_valid "$id" || { printf 'escalate: malformed id %s\n' "$id" >&2; return 2; }
  dir="$(esc__dir)"
  [ -r "$dir/$id.payload" ] || { printf 'escalate: no payload recorded for %s\n' "$id" >&2; return 1; }
  # A record that does not re-derive its own id has been altered since it was
  # written. Say so before printing anything, so nobody quotes tampered bytes
  # into a Decision Card.
  local integ
  if ! integ="$(esc_record_integrity "$id")"; then
    printf 'escalate: WARNING -- this record does not re-derive: %s\n' "$integ" >&2
    printf '  approve.sh will refuse it. Do not quote these bytes anywhere.\n' >&2
  fi
  printf -- '--- exact refused bytes (%s) ---\n' "$id"
  cat "$dir/$id.payload"
  printf '\n--- end ---\n'
  return 0
}

esc_sh__selftest() {
  local fail=0 root
  root="$(mktemp -d)" || { echo "FAIL mktemp"; return 1; }
  ESC_SELFTEST=1
  REPO_ROOT="$root"
  ESCALATIONS_DIR="$root/.pipeline/escalations"
  ESCALATION_LEDGER="$root/.pipeline/escalations/ledger.jsonl"
  ESCALATION_KEY="$root/secrets/escalation.key"
  RUN_ACTIVE="$root/.pipeline/run-active"
  RUN_START="$root/.pipeline/run-start"
  HOOKS_DIR="$ESC_SH_DIR"
  ESCALATION_MODE=light
  DOMAIN_NEVER_ESCALATABLE=""
  mkdir -p "$ESCALATIONS_DIR" "$root/secrets"
  printf 'M1\n' > "$RUN_ACTIVE"; printf '1700000000\n' > "$RUN_START"

  local id nid rc
  id="$(esc_record_refusal delete-scope Bash 'rm -rf docs/old')"
  nid="$(esc_record_refusal force-push Bash 'git push --force')"

  # Capture-then-grep, never `cmd | grep -q`: under `set -o pipefail` grep -q
  # closes the pipe early, the writer takes SIGPIPE and the pipeline reports a
  # failure for a test that passed.
  _grep() { # <name> <pattern> <cmd...>
    local name="$1" pat="$2"; shift 2
    local out; out="$(mktemp)"
    "$@" > "$out" 2>&1
    grep -q -- "$pat" "$out" || { echo "FAIL $name (pattern not found: $pat)"; fail=1; }
    rm -f "$out"
  }

  esc_sh__request "$id" "the directory is a stale scaffold the manifest declares removed" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL confirmable request rejected (rc=$rc)"; fail=1; }
  [ -r "$ESCALATIONS_DIR/$id.why" ] || { echo "FAIL why sidecar not written"; fail=1; }
  [ -r "$ESCALATIONS_DIR/$id.request" ] || { echo "FAIL request marker not written"; fail=1; }
  # the justification must NOT be in the json
  if grep -qi 'scaffold' "$ESCALATIONS_DIR/$id.request" 2>/dev/null; then
    echo "FAIL free text leaked into the request JSON"; fail=1
  fi
  # the printed human command must name approve.sh and the id
  _grep "human command printed" "approve.sh $id" esc_sh__request "$id" "again"

  esc_sh__request "$nid" "I really need it" >/dev/null 2>&1
  [ "$?" -eq 4 ] || { echo "FAIL never-escalatable request was not refused"; fail=1; }
  _grep "never message says NEVER-ESCALATABLE" 'NEVER-ESCALATABLE' esc_sh__request "$nid" "I really need it"
  _grep "never message points at the Hard Stop flow" 'Hard Stop' esc_sh__request "$nid" "I really need it"
  _grep "never message says no approval exists" 'No approval exists' esc_sh__request "$nid" "I really need it"

  esc_sh__request "esc-0000000000000000" "x" >/dev/null 2>&1
  [ "$?" -eq 1 ] || { echo "FAIL unknown id accepted"; fail=1; }
  esc_sh__request "not-an-id" "x" >/dev/null 2>&1
  [ "$?" -eq 2 ] || { echo "FAIL malformed id accepted"; fail=1; }
  esc_sh__request "$id" "" >/dev/null 2>&1
  [ "$?" -eq 2 ] || { echo "FAIL empty justification accepted"; fail=1; }

  # ambiguous Edit refusal
  mkdir -p "$root/src"
  printf 'dup\ndup\n' > "$root/src/f.txt"
  local aid apayload
  apayload='{"tool_name":"Edit","tool_input":{"file_path":"src/f.txt","old_string":"dup","new_string":"x"}}'
  aid="$(esc_record_refusal claude-dir-write Edit "$apayload")"
  if [ "$(esc_json_get "$ESCALATIONS_DIR/$aid.json" target_kind)" = "ambiguous" ]; then
    esc_sh__request "$aid" "why" >/dev/null 2>&1
    [ "$?" -eq 5 ] || { echo "FAIL ambiguous edit request not refused"; fail=1; }
    _grep "ambiguous remedy stated" 'Write with the COMPLETE file content' esc_sh__request "$aid" "why"
  else
    echo "WARN could not construct the ambiguous case (esc_payload.py unavailable?)"
  fi

  esc_sh__status "$id" >/dev/null 2>&1 || { echo "FAIL status"; fail=1; }
  esc_sh__list >/dev/null 2>&1 || { echo "FAIL list"; fail=1; }
  _grep "show prints the exact refused bytes" 'rm -rf docs/old' esc_sh__show "$id"

  rm -rf "$root" 2>/dev/null
  unset -f _grep
  if [ "$fail" -eq 0 ]; then echo "escalate.sh selftest PASS"; else echo "escalate.sh selftest FAIL"; fi
  return "$fail"
}

main() {
  case "${1:---help}" in
    request)  shift; esc_sh__request "${1:-}" "${2:-}"; exit $? ;;
    status)   shift; esc_sh__status "${1:-}"; exit $? ;;
    show)     shift; esc_sh__show "${1:-}"; exit $? ;;
    list)     esc_sh__list; exit $? ;;
    postcondition-status)
      if esc_postcondition_pending; then
        printf 'A control-layer postcondition is PENDING.\n'
        cat "$(esc__pc_marker)" 2>/dev/null
        printf '\nRemedy (this exact command is always permitted):\n  %s\n' "$(esc_postcondition_remedy_cmd)"
        exit 0
      fi
      printf 'No control-layer postcondition pending.\n'; exit 1 ;;
    postcondition-clear) esc_postcondition_clear; exit $? ;;
    --selftest) esc_sh__selftest; exit $? ;;
    --help|-h)  esc_sh__usage; exit 0 ;;
    *) esc_sh__usage; exit 2 ;;
  esac
}

main "$@"
