#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/approve.sh
#
# HUMANS: THIS FILE IS YOURS. You run it, in your own terminal, and nothing
# else in the harness can. If you are reading this because an agent asked you
# to run something, read the bytes it shows you before you type the id back.
#
# Contract ............ CONTRACT.md §5.5 (approvals, disclosure), §5.6 (never-
#                       escalatable core), §3 (human-only, denied to the agent
#                       at three layers)
# Invocation .......... approve.sh <id>                 sign one refused call
#                       approve.sh --disclose <check>   sign a disclosed red
#                       approve.sh --init-key           create the signing key
#                       approve.sh --postcondition-baseline
#                       approve.sh --list | --selftest | --help
# Blocking mechanism .. NONE. This script only ever grants; it never runs the
#                       approved command. The agent re-issues its own call and
#                       the guard consumes the approval.
#
# -----------------------------------------------------------------------------
# THE THREE LAYERS THAT KEEP THIS OUT OF THE AGENT'S HANDS
#   1. settings.json  -- a deny entry on Bash commands matching approve.sh
#                        (the installer writes it; see the integrator notes).
#   2. guard.sh       -- rule `approve-script-invocation`, classified
#                        NEVER-escalatable. guard.sh calls
#                        esc_cmd_invokes_approve() from escalation-lib.sh so
#                        the detection lives in one place and is by effect,
#                        not by verb token (CONTRACT §0.4).
#   3. this script    -- the checks in esc_ap__require_human below: a TTY on
#                        stdin, no agent-context environment markers, and the
#                        human retyping the id by hand.
#
# Any one of those alone would be a speed bump. The property that actually
# holds is different and simpler: THE AGENT CANNOT READ $ESCALATION_KEY. Even
# a perfect bypass of all three layers gets an agent to a script that will fail
# to compute a MAC. The layers exist so that failure is loud and early rather
# than a confusing dead end.
#
# WHAT AN APPROVAL IS, PRECISELY
#   An HMAC-SHA256 over  version|id|rule|tool|target_sha|run_token|expiry.
#   Single-use, TTL-bound (default 30 min), bound to THIS run, and bound to the
#   EXACT BYTES that were refused. It lifts ONE rule for ONE call. It does not
#   lift the other rules, it does not create a standing exception, and it does
#   not survive gate closure.
#
# WHAT A DISCLOSURE IS, PRECISELY
#   Never "this check passes". Only: a human read THIS EXACT FAILURE TEXT and
#   ruled the run may ship with it DISCLOSED. It binds to the failure text, so
#   a different failure of the same check is undisclosed and blocks. It is
#   excluded from the exit code only, is reprinted in full at every subsequent
#   block, and dies at gate closure.
# =============================================================================

set -uo pipefail

AP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

# shellcheck disable=SC1090,SC1091
if [ -r "$AP_DIR/escalation-lib.sh" ]; then
  . "$AP_DIR/escalation-lib.sh"
else
  printf 'approve: cannot load escalation-lib.sh from %s\n' "$AP_DIR" >&2
  exit 1
fi

esc_ap__usage() {
  cat <<'USAGE'
approve.sh -- the human half of Ratchet's escalation flow. Run it yourself.

  approve.sh <id>
      Show the exact bytes that were refused, make you retype the id, and sign
      a single-use, time-bound, run-bound approval for that one call.

  approve.sh --disclose <check-id>
      Show a check's exact failure text and sign a DISCLOSURE: not "it passes",
      but "a human read this failure and ruled the run may ship with it
      disclosed". Binds to the failure text; a different failure blocks again.

  approve.sh --init-key
      Create secrets/escalation.key (0600) and verify secrets/ is gitignored.
      Refuses to create a key that git would track.

  approve.sh --postcondition-baseline
      Record the control-layer selftest failures ALREADY present on this host,
      so a pre-existing failure cannot wedge the run forever.

  approve.sh --list        show pending requests
  approve.sh --selftest    run the built-in tests (no TTY required)

Nothing here approves a rule. Everything here approves one call.
USAGE
}

# ---------------------------------------------------------------------------
# Layer 3: is a human really at the keyboard?
# ---------------------------------------------------------------------------
esc_ap__require_human() {
  if [ "${ESC_SELFTEST:-0}" = "1" ]; then return 0; fi

  # Agent-context markers. If the harness is running us from inside a Claude
  # Code session, we are not a human terminal no matter what stdin says.
  local marker
  for marker in CLAUDECODE CLAUDE_CODE_ENTRYPOINT RATCHET_HOOK_CONTEXT ESC_AGENT_CONTEXT; do
    if [ -n "$(eval "printf '%s' \"\${$marker:-}\"")" ]; then
      printf 'approve: refusing -- running inside an agent session (%s is set).\n' "$marker" >&2
      printf '  Open your own terminal and run this there. An approval signed from inside the\n' >&2
      printf '  session it authorises is not a second factor; it is the same factor twice.\n' >&2
      return 1
    fi
  done

  if [ ! -t 0 ]; then
    printf 'approve: refusing -- stdin is not a terminal.\n' >&2
    printf '  This script must be run interactively by a human. Piping input to it, or calling\n' >&2
    printf '  it from a script, defeats the only step that makes consent mean anything: a\n' >&2
    printf '  person reading the exact bytes before signing them.\n' >&2
    return 1
  fi
  return 0
}

esc_ap__confirm_id() {  # <expected> <label>
  local expected="$1" label="${2:-id}" typed=""
  if [ "${ESC_SELFTEST:-0}" = "1" ]; then return 0; fi
  printf '\nRetype the %s to sign (or anything else to abort): ' "$label"
  IFS= read -r typed || return 1
  typed="${typed//$'\r'/}"
  typed="${typed#"${typed%%[![:space:]]*}"}"
  typed="${typed%"${typed##*[![:space:]]}"}"
  if [ "$typed" != "$expected" ]; then
    printf '\napprove: aborted. You typed "%s"; the %s is "%s". Nothing was signed.\n' \
      "$typed" "$label" "$expected" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --init-key
# ---------------------------------------------------------------------------
esc_ap__gitignored() {  # <repo-relative path> -> 0 if git would ignore it
  command -v git >/dev/null 2>&1 || return 2
  ( cd "${REPO_ROOT:-$PWD}" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ) || return 2
  ( cd "${REPO_ROOT:-$PWD}" && git check-ignore -q "$1" >/dev/null 2>&1 )
}

esc_ap__init_key() {
  local kp kdir rel hex
  kp="$(esc__keypath)"
  kdir="$(dirname "$kp")"
  rel="${ESCALATION_KEY}"

  if [ -e "$kp" ]; then
    printf 'approve: a key already exists at %s.\n' "$kp" >&2
    printf '  Refusing to overwrite it. Rotating the key invalidates every outstanding\n' >&2
    printf '  approval, which is fine -- but do it deliberately: move the old file aside\n' >&2
    printf '  yourself, then run --init-key again.\n' >&2
    return 1
  fi

  mkdir -p "$kdir" 2>/dev/null || { printf 'approve: cannot create %s\n' "$kdir" >&2; return 1; }
  chmod 700 "$kdir" 2>/dev/null || true

  # THE GITIGNORE CHECK IS A HARD FAIL, NOT A WARNING. A signing key that git
  # would track is a key that ends up in a PR diff. Fail closed (§0.3).
  esc_ap__gitignored "$rel"
  case "$?" in
    0) : ;;
    2) printf 'approve: cannot determine whether %s is gitignored (no git repo here).\n' "$rel" >&2
       printf '  Refusing to create a key I cannot prove git will ignore.\n' >&2
       return 1 ;;
    *) printf 'approve: REFUSING -- %s is NOT gitignored.\n' "$rel" >&2
       printf '  Add this to .gitignore first, then re-run:\n\n' >&2
       printf '    %s/\n\n' "${SECRETS_DIR%/}" >&2
       printf '  A signing key that git tracks is a signing key that ships in a diff.\n' >&2
       return 1 ;;
  esac

  if command -v openssl >/dev/null 2>&1; then
    hex="$(openssl rand -hex 32 2>/dev/null)"
  fi
  if [ -z "${hex:-}" ]; then
    local py; py="$(esc__py 2>/dev/null)"
    [ -n "$py" ] && hex="$("$py" -c 'import secrets;print(secrets.token_hex(32))' 2>/dev/null)"
  fi
  if [ -z "${hex:-}" ] && [ -r /dev/urandom ]; then
    hex="$(od -An -v -tx1 -N32 < /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  hex="${hex//$'\r'/}"
  if [ "${#hex}" -lt 32 ]; then
    printf 'approve: could not generate key material (no openssl, no python3, no /dev/urandom).\n' >&2
    return 1
  fi

  ( umask 077; printf '%s\n' "$hex" > "$kp" ) || return 1
  chmod 600 "$kp" 2>/dev/null || true
  esc_key_valid "$kp" || { printf 'approve: generated key failed validation.\n' >&2; return 1; }

  printf 'Created %s (0600), %d hex chars.\n' "$kp" "${#hex}"
  printf 'Verified: git ignores %s.\n' "$rel"
  printf '\nThe agent is denied this file at the settings layer AND the guard layer, and that\n'
  printf 'deny is never-escalatable. Do not copy it into the repo, an env var, or a chat.\n'
  esc__ledger_append "key_initialized" "-" "escalation-key-access" "-" "-" "-" || true
  return 0
}

# ---------------------------------------------------------------------------
# --postcondition-baseline
# ---------------------------------------------------------------------------
esc_ap__baseline() {
  printf 'Running the control-layer selftest to record the CURRENT failure floor...\n\n'
  esc_postcondition_baseline_write
  printf '\nFrom now on, a control-layer postcondition clears when the failure set is a\n'
  printf 'SUBSET of this baseline. New failures still block. Re-run this only when you have\n'
  printf 'deliberately accepted a new pre-existing failure.\n'
  esc__ledger_append "postcondition_baselined" "-" "control-layer-write" "-" "-" "-" || true
  return 0
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
esc_ap__list() {
  local dir f id n=0
  dir="$(esc__dir)"
  [ -d "$dir" ] || { printf 'No escalation requests.\n'; return 0; }
  for f in "$dir"/esc-*.request; do
    [ -r "$f" ] || continue
    id="$(esc_json_get "$f" id 2>/dev/null)" || continue
    n=$(( n + 1 ))
    printf -- '--- %s\n' "$id"
    printf '  rule     %s (%s)\n' "$(esc_json_get "$f" rule)" "$(esc_classify "$(esc_json_get "$f" rule)" 2>/dev/null)"
    printf '  tool     %s\n' "$(esc_json_get "$f" tool)"
    printf '  asked    %s\n' "$(esc_json_get "$f" requested_at)"
    if [ -r "$dir/$id.why" ]; then
      printf '  why      '
      sed -e 's/^/           /' "$dir/$id.why" 2>/dev/null | sed -e '1s/^ *//'
    fi
    if [ -r "$dir/$id.approval" ]; then printf '  state    ALREADY SIGNED (unconsumed)\n'
    elif [ -r "$dir/$id.approval.consumed" ]; then printf '  state    signed and consumed\n'
    else printf '  state    awaiting you: bash %s/approve.sh %s\n' "$HOOKS_DIR" "$id"; fi
  done
  [ "$n" -eq 0 ] && printf 'No escalation requests.\n'
  return 0
}

# ---------------------------------------------------------------------------
# approve.sh <id> -- the main event
# ---------------------------------------------------------------------------
esc_ap__approve() {
  local id="${1:-}"
  printf '%s' "$id" | grep -Eq '^esc-[0-9a-f]{16}$' || {
    printf 'approve: malformed id %s (expected esc-<16 hex>).\n' "$id" >&2; return 2; }

  esc_ap__require_human || return 1

  local dir rec; dir="$(esc__dir)"; rec="$dir/$id.json"
  [ -r "$rec" ] || { printf 'approve: no refusal recorded under %s.\n' "$id" >&2; return 1; }

  # Re-derive the record from its own bytes BEFORE showing a human anything.
  # Refusal records live in agent scratch, so "the bytes that were refused"
  # is a claim until it is re-derived. If this fails, do not print the payload
  # at all -- printing tampered bytes and then refusing still shows the human
  # the attacker's text.
  local integ
  if ! integ="$(esc_record_integrity "$id")"; then
    printf 'approve: REFUSING -- the refusal record for %s does not re-derive.\n' "$id" >&2
    printf '  %s\n' "$integ" >&2
    printf '  The id is a hash of (rule, tool, payload bytes), so a record that does not\n' >&2
    printf '  re-derive its own id has been altered since it was written. Nothing is shown and\n' >&2
    printf '  nothing is signed. Treat this as a security finding, not a glitch.\n' >&2
    esc__ledger_append "sign_refused_tampered" "$id" "-" "-" "-" "-" || true
    return 7
  fi

  local rule tool class tsha tkind tpath psha plen rtok rec_tok
  rule="$(esc_json_get "$rec" rule)"
  tool="$(esc_json_get "$rec" tool)"
  tsha="$(esc_json_get "$rec" target_sha)"
  tkind="$(esc_json_get "$rec" target_kind)"
  tpath="$(esc_json_get "$rec" target_path)"
  psha="$(esc_json_get "$rec" payload_sha)"
  plen="$(esc_json_get "$rec" payload_len)"
  rec_tok="$(esc_json_get "$rec" run_token)"
  class="$(esc_classify "$rule" 2>/dev/null)"

  # --- the wall, repeated here so it holds even if escalate.sh was bypassed --
  if [ "$class" != "confirmable" ]; then
    printf 'approve: REFUSING to sign.\n' >&2
    if [ "$class" = "unknown" ]; then
      printf '  Rule "%s" is not in the harness rule vocabulary, so it is treated as\n' "$rule" >&2
      printf '  never-escalatable (fail closed). Classify it in escalation-lib.sh first.\n' >&2
    else
      printf '  Rule "%s" is NEVER-ESCALATABLE (CONTRACT 5.6). No approval exists that lifts\n' "$rule" >&2
      printf '  it -- including one you sign right now. The guard would refuse the call anyway.\n' >&2
    fi
    esc__ledger_append "sign_refused_class" "$id" "$rule" "$tool" "$tsha" "-" || true
    return 4
  fi
  case "$tkind" in
    ambiguous|unsupported|error|underivable)
      printf 'approve: REFUSING to sign -- the resulting bytes are not derivable (%s).\n' "$tkind" >&2
      printf '  Ask the agent to re-issue as Write with the complete file content.\n' >&2
      return 5 ;;
  esac

  rtok="$(esc_run_token)" || { printf 'approve: cannot derive the run token.\n' >&2; return 1; }
  if [ -n "$rec_tok" ] && [ "$rec_tok" != "$rtok" ]; then
    printf 'approve: REFUSING -- that refusal belongs to a different run.\n' >&2
    printf '  Approvals die at gate closure. Have the agent re-issue the call.\n' >&2
    return 6
  fi
  esc_key_valid "$(esc__keypath)" || {
    printf 'approve: no usable signing key at %s. Run: approve.sh --init-key\n' "$(esc__keypath)" >&2
    return 1; }

  # --- SHOW THE HUMAN THE EXACT BYTES (invariant I4) -----------------------
  printf '\n'
  printf '================================================================\n'
  printf ' RATCHET ESCALATION -- review before you sign\n'
  printf '================================================================\n'
  printf ' id           %s\n' "$id"
  printf ' rule         %s   (confirmable, %s mode)\n' "$rule" "$(esc_mode)"
  printf ' tool         %s\n' "$tool"
  [ "$tpath" != "-" ] && printf ' target file  %s\n' "$tpath"
  printf ' payload      %s bytes, sha256 %s\n' "$plen" "$psha"
  printf ' signs        %s\n' "$tsha"
  printf ' ttl          %s seconds, single use, this run only\n' "${ESCALATION_TTL_SECONDS:-1800}"
  if [ -r "$dir/$id.why" ]; then
    printf '\n---------------- the agent says ----------------\n'
    cat "$dir/$id.why"
  else
    printf '\n(no justification was filed -- the agent skipped escalate.sh request)\n'
  fi
  printf '\n------------- EXACT REFUSED BYTES --------------\n'
  if [ -r "$dir/$id.payload" ]; then
    cat "$dir/$id.payload"
    printf '\n'
  else
    printf '(payload sidecar missing -- REFUSING)\n' >&2
    return 1
  fi
  printf -- '------------------------------------------------\n'
  if [ -r "$dir/$id.target" ]; then
    printf '\n--- RESULTING FILE CONTENT (%s) ---\n' "$tpath"
    cat "$dir/$id.target"
    printf -- '\n--- end of resulting file ---\n'
  fi
  printf '\nThis lifts ONE rule for ONE call. It does not lift the other rules, it does not\n'
  printf 'create a standing exception, and it dies at gate closure.\n'

  # A write under the control layer arms the postcondition: the control-layer
  # selftest must pass before the next tool call. Say so BEFORE signing.
  local arms_pc=0
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      case "$tpath" in
        "${CLAUDE_DIR#./}"/*|./"${CLAUDE_DIR#./}"/*) arms_pc=1 ;;
      esac ;;
  esac
  if [ "$arms_pc" -eq 1 ]; then
    printf '\nNOTE: this writes under %s. After it lands, the control-layer selftest must run\n' "$CLAUDE_DIR"
    printf 'and pass before any further tool call is permitted. An approved edit that breaks\n'
    printf 'the guards is the one state where no later refusal can be trusted.\n'
  fi

  esc_ap__confirm_id "$id" "id" || return 1

  # esc__sign_fresh, not esc__sign: the frozen MAC tuple has no nonce, so
  # approving the same call twice within the same second would mint a
  # byte-identical signature and single-use would reject the second as a
  # replay of the first. Asking twice is legitimate. It nudges the expiry
  # forward until the signature is new and tells us which expiry it signed.
  local exp mac fresh
  exp=$(( $(esc__now) + ${ESCALATION_TTL_SECONDS:-1800} ))
  fresh="$(esc__sign_fresh "$id" "$rule" "$tool" "$tsha" "$rtok" "$exp")" || {
    printf 'approve: could not compute the MAC (no python3 and no usable openssl).\n' >&2
    return 1; }
  exp="${fresh%% *}"; mac="${fresh##* }"

  esc__ensure_dir || return 1
  esc__json_write "$dir/$id.approval" \
    version esc/1 \
    kind approval \
    id "$id" \
    rule "$rule" \
    tool "$tool" \
    target_sha "$tsha" \
    run_token "$rtok" \
    expiry "$exp" \
    signed_at "$(esc__now)" \
    mac "$mac" || { printf 'approve: could not write the approval.\n' >&2; return 1; }
  chmod 600 "$dir/$id.approval" 2>/dev/null || true

  [ "$arms_pc" -eq 1 ] && esc_postcondition_arm "approved write under $CLAUDE_DIR ($tpath)"

  esc__ledger_append "signed" "$id" "$rule" "$tool" "$tsha" "$(esc__sha256_str "$mac")" || true

  printf '\nSIGNED. Valid for %s seconds, one use, this run only.\n' "${ESCALATION_TTL_SECONDS:-1800}"
  printf 'Tell the agent to re-issue the IDENTICAL call. One byte different is a different\n'
  printf 'call and will be refused, correctly.\n'
  return 0
}

# ---------------------------------------------------------------------------
# --disclose <check-id>
# ---------------------------------------------------------------------------
esc_ap__disclose() {
  local check="${1:-}" ftext_file="${2:-}"
  esc_check_id_valid "$check" || {
    printf 'approve: malformed check id %s.\n' "$check" >&2; return 2; }

  esc_ap__require_human || return 1

  local dir; dir="$(esc__dir)"
  [ -n "$ftext_file" ] || ftext_file="$dir/failures/$check.txt"
  if [ ! -r "$ftext_file" ]; then
    printf 'approve: no recorded failure text for check "%s".\n' "$check" >&2
    printf '  A disclosure binds to the FAILURE TEXT, not the check id, so there is nothing\n' >&2
    printf '  to bind to until the check has actually failed and the gate recorded it at\n' >&2
    printf '    %s\n' "$dir/failures/$check.txt" >&2
    printf '  Run the gate, then disclose. Or pass the failure file explicitly:\n' >&2
    printf '    approve.sh --disclose %s <path-to-failure-text>\n' "$check" >&2
    return 1
  fi

  esc_key_valid "$(esc__keypath)" || {
    printf 'approve: no usable signing key. Run: approve.sh --init-key\n' >&2; return 1; }

  local fsha rsha rtok exp mac
  fsha="$(esc__fail_sha "$check" < "$ftext_file")" || return 1
  # The RAW sha of the failure bytes as check_done.py computes it. The MAC
  # still covers the canonical (normalised) hash; this is only a lookup key so
  # check_done.py can find the disclosure without knowing our normalisation.
  rsha="$(esc__sha256_file "$ftext_file")" || return 1
  rtok="$(esc_run_token)" || return 1

  printf '\n'
  printf '================================================================\n'
  printf ' RATCHET DISCLOSURE -- this is NOT "the check passes"\n'
  printf '================================================================\n'
  printf ' check        %s\n' "$check"
  printf ' failure sha  %s\n' "$fsha"
  printf '\n--------------- EXACT FAILURE TEXT -------------\n'
  cat "$ftext_file"
  printf -- '\n------------------------------------------------\n'
  printf '\nSigning this records: a human read THIS EXACT FAILURE and ruled the run may ship\n'
  printf 'with it disclosed. Consequences, precisely:\n'
  printf '  - check_done.py renders it DISCLOSED, never PASS;\n'
  printf '  - it is excluded from the exit code ONLY;\n'
  printf '  - the Stop gate reprints it IN FULL at every subsequent block;\n'
  printf '  - a DIFFERENT failure of the same check is undisclosed and blocks;\n'
  printf '  - it dies at gate closure.\n'
  printf '\nIf you are signing this to get unblocked rather than because the red is settled,\n'
  printf 'stop. If you find yourself disclosing the same check twice, the check is wrong and\n'
  printf 'that is a refinement, not a third disclosure.\n'

  esc_ap__confirm_id "$check" "check id" || return 1

  # expiry 0 = no clock. A disclosure dies at gate closure, not on a timer:
  # a red that is settled does not become unsettled 30 minutes later.
  # Plain esc__sign here, NOT esc__sign_fresh: 0 is a sentinel, and nudging it
  # forward would turn it into the epoch timestamp 1, i.e. instantly expired.
  # Disclosures are not single-use anyway, so a repeat disclosure of the same
  # text is idempotent by design -- it rewrites the same file with the same MAC.
  exp=0
  mac="$(esc__sign "disclose-$check" "disclosure" "$check" "$fsha" "$rtok" "$exp")" || {
    printf 'approve: could not compute the MAC.\n' >&2; return 1; }

  esc__ensure_dir || return 1
  cp -f "$ftext_file" "$dir/disclosure-$check-${fsha:0:8}.failure" 2>/dev/null || return 1
  esc__json_write "$dir/disclosure-$check-${fsha:0:8}.json" \
    version esc/1 \
    kind disclosure \
    check "$check" \
    fail_sha "$fsha" \
    raw_sha "$rsha" \
    run_token "$rtok" \
    expiry "$exp" \
    signed_at "$(esc__now)" \
    mac "$mac" || return 1
  esc__ledger_append "disclosed" "disclose-$check" "disclosure" "$check" "$fsha" "$(esc__sha256_str "$mac")" || true

  printf '\nDISCLOSED. The check still fails; it is now excluded from the exit code and will be\n'
  printf 'reprinted in full at every block until gate closure.\n'
  return 0
}

# ---------------------------------------------------------------------------
esc_ap__selftest() {
  local fail=0 root
  root="$(mktemp -d)" || { echo "FAIL mktemp"; return 1; }
  ESC_SELFTEST=1
  REPO_ROOT="$root"
  ESCALATIONS_DIR="$root/.pipeline/escalations"
  ESCALATION_LEDGER="$root/.pipeline/escalations/ledger.jsonl"
  ESCALATION_KEY="$root/secrets/escalation.key"
  SECRETS_DIR="secrets"
  RUN_ACTIVE="$root/.pipeline/run-active"
  RUN_START="$root/.pipeline/run-start"
  HOOKS_DIR="$AP_DIR"
  CLAUDE_DIR=".claude"
  ESCALATION_TTL_SECONDS=1800
  ESCALATION_MODE=light
  DOMAIN_NEVER_ESCALATABLE=""
  mkdir -p "$ESCALATIONS_DIR" "$root/.claude/hooks" "$root/src"
  printf 'M1\n' > "$RUN_ACTIVE"; printf '1700000000\n' > "$RUN_START"

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

  # --- --init-key refuses when secrets/ is not gitignored -------------------
  ( cd "$root" && git init -q . >/dev/null 2>&1 )
  if [ -d "$root/.git" ]; then
    esc_ap__init_key >/dev/null 2>&1
    [ "$?" -ne 0 ] || { echo "FAIL init-key created a key in a repo with no gitignore"; fail=1; }
    [ -e "$root/secrets/escalation.key" ] && { echo "FAIL init-key left a key behind"; fail=1; }
    printf 'secrets/\n' > "$root/.gitignore"
    esc_ap__init_key >/dev/null 2>&1
    [ "$?" -eq 0 ] || { echo "FAIL init-key refused a properly gitignored path"; fail=1; }
    [ -r "$root/secrets/escalation.key" ] || { echo "FAIL init-key wrote no key"; fail=1; }
    case "$(ls -l "$root/secrets/escalation.key" 2>/dev/null | cut -c1-10)" in
      -rw-------) : ;;
      *) echo "WARN key mode is not 0600 on this filesystem" ;;
    esac
    esc_ap__init_key >/dev/null 2>&1
    [ "$?" -ne 0 ] || { echo "FAIL init-key overwrote an existing key"; fail=1; }
  else
    echo "WARN git unavailable; skipping --init-key gitignore tests"
    mkdir -p "$root/secrets"
    printf '%s\n' "$(openssl rand -hex 32 2>/dev/null || echo aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899)" > "$ESCALATION_KEY"
  fi
  esc_key_valid "$ESCALATION_KEY" || { echo "FAIL key not valid"; fail=1; }

  # --- signing a confirmable refusal ---------------------------------------
  local id nid tsha
  id="$(esc_record_refusal delete-scope Bash 'rm -rf docs/old')"
  tsha="$(esc_json_get "$ESCALATIONS_DIR/$id.json" target_sha)"
  esc_ap__approve "$id" >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL approve did not sign a confirmable refusal"; fail=1; }
  [ -r "$ESCALATIONS_DIR/$id.approval" ] || { echo "FAIL no approval file"; fail=1; }
  esc_peek_approval delete-scope Bash "$tsha" "$id" \
    || { echo "FAIL signed approval does not verify"; fail=1; }
  esc_check_approval delete-scope Bash "$tsha" "$id" \
    || { echo "FAIL signed approval not accepted by the guard path"; fail=1; }
  esc_check_approval delete-scope Bash "$tsha" "$id" 2>/dev/null \
    && { echo "FAIL approval was reusable"; fail=1; }

  # --- refuses never-escalatable -------------------------------------------
  nid="$(esc_record_refusal force-push Bash 'git push --force origin main')"
  esc_ap__approve "$nid" >/dev/null 2>&1
  [ "$?" -eq 4 ] || { echo "FAIL approve signed a never-escalatable rule"; fail=1; }
  [ -r "$ESCALATIONS_DIR/$nid.approval" ] && { echo "FAIL approval file for a never rule"; fail=1; }
  _grep "approve says NEVER-ESCALATABLE" 'NEVER-ESCALATABLE' esc_ap__approve "$nid"

  # --- refuses an unclassified rule ----------------------------------------
  local uid
  uid="$(esc_record_refusal totally-unknown-rule Bash 'echo hi' 2>/dev/null)"
  esc_ap__approve "$uid" >/dev/null 2>&1
  [ "$?" -eq 4 ] || { echo "FAIL approve signed an unclassified rule"; fail=1; }
  rm -f "$ESCALATIONS_DIR/unclassified-rules.log"

  # --- refuses a tampered record -------------------------------------------
  local tid
  tid="$(esc_record_refusal compound-git-form Bash 'git add -A && git commit -m ok')"
  printf 'git push --force origin main' > "$ESCALATIONS_DIR/$tid.payload"
  esc_ap__approve "$tid" >/dev/null 2>&1
  [ "$?" -eq 7 ] || { echo "FAIL approve signed a tampered record"; fail=1; }
  [ -r "$ESCALATIONS_DIR/$tid.approval" ] && { echo "FAIL approval file for a tampered record"; fail=1; }
  # and it must not have echoed the attacker's bytes to the human
  local tout; tout="$(mktemp)"
  esc_ap__approve "$tid" > "$tout" 2>&1
  grep -q 'push --force' "$tout" && { echo "FAIL tampered bytes were shown to the human"; fail=1; }
  rm -f "$tout"

  # --- refuses an ambiguous Edit -------------------------------------------
  printf 'dup\ndup\n' > "$root/src/f.txt"
  local aid
  aid="$(esc_record_refusal claude-dir-write Edit \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/f.txt","old_string":"dup","new_string":"x"}}')"
  if [ "$(esc_json_get "$ESCALATIONS_DIR/$aid.json" target_kind)" = "ambiguous" ]; then
    esc_ap__approve "$aid" >/dev/null 2>&1
    [ "$?" -eq 5 ] || { echo "FAIL approve signed an ambiguous edit"; fail=1; }
  fi

  # --- an approved .claude/ write arms the postcondition -------------------
  printf 'x\n' > "$root/.claude/hooks/notes.md"
  local cid ctsha
  cid="$(esc_record_refusal claude-dir-write Write \
    '{"tool_name":"Write","tool_input":{"file_path":".claude/hooks/notes.md","content":"y\n"}}')"
  esc_ap__approve "$cid" >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL approve refused a legitimate .claude write"; fail=1; }
  esc_postcondition_pending || { echo "FAIL postcondition not armed by a .claude write"; fail=1; }
  # ... and the remedy is reachable while it is armed
  esc_postcondition_is_remedy "$(esc_postcondition_remedy_cmd)" \
    || { echo "FAIL remedy command is not recognised as the remedy"; fail=1; }
  # ... and clearing works against an empty baseline when nothing is broken
  : > "$ESCALATIONS_DIR/postcondition-baseline.txt"
  RATCHET_CONTROL_SELFTEST="true" esc_postcondition_clear >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL postcondition would not clear on a green selftest"; fail=1; }
  esc_postcondition_pending && { echo "FAIL marker survived a green clear"; fail=1; }
  # ... and a NEW failure does not clear
  esc_postcondition_arm "test" >/dev/null 2>&1
  RATCHET_CONTROL_SELFTEST="false" esc_postcondition_clear >/dev/null 2>&1
  [ "$?" -ne 0 ] || { echo "FAIL postcondition cleared on a red selftest"; fail=1; }
  esc_postcondition_pending || { echo "FAIL marker removed despite a red selftest"; fail=1; }
  # ... and a pre-existing failure recorded as the baseline is a floor
  printf 'FAIL custom-control-selftest\n' > "$ESCALATIONS_DIR/postcondition-baseline.txt"
  RATCHET_CONTROL_SELFTEST="false" esc_postcondition_clear >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL baseline floor did not permit a pre-existing failure"; fail=1; }
  rm -f "$ESCALATIONS_DIR/postcondition-baseline.txt"

  # --- disclosure ----------------------------------------------------------
  esc_record_failure cov-gate 'coverage 81.2% < 85%'
  esc_ap__disclose cov-gate >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL disclose did not sign"; fail=1; }
  esc_disclose_verify cov-gate 'coverage 81.2% < 85%' || { echo "FAIL disclosure does not verify"; fail=1; }
  esc_disclose_verify cov-gate 'coverage 79.0% < 85%' 2>/dev/null \
    && { echo "FAIL a different failure verified against the disclosure"; fail=1; }
  _grep "disclosure reprinted in full" '81.2%' esc_list_disclosures
  # a check that never failed cannot be disclosed
  esc_ap__disclose never-ran-gate >/dev/null 2>&1
  [ "$?" -ne 0 ] || { echo "FAIL disclosed a check with no recorded failure"; fail=1; }
  # check_done.py's adapter: it hashes the RAW detail string it renders.
  local rawsha
  rawsha="$(printf '%s' 'coverage 81.2% < 85%' | esc__sha256_stdin)"
  rt_esc_disclosed cov-gate "$rawsha" \
    || { echo "FAIL rt_esc_disclosed (check_done.py adapter) did not match"; fail=1; }
  rt_esc_disclosed cov-gate "$(printf '%s' 'coverage 79.0% < 85%' | esc__sha256_stdin)" 2>/dev/null \
    && { echo "FAIL rt_esc_disclosed matched a different failure"; fail=1; }
  rt_esc_disclosed other-gate "$rawsha" 2>/dev/null \
    && { echo "FAIL rt_esc_disclosed matched a different check"; fail=1; }
  rt_esc_never_escalatable force-push || { echo "FAIL rt_esc_never_escalatable"; fail=1; }
  rt_esc_never_escalatable delete-scope 2>/dev/null && { echo "FAIL rt_esc_never_escalatable said never for a confirmable rule"; fail=1; }
  rt_esc_never_list | grep -qx 'force-push' || { echo "FAIL rt_esc_never_list"; fail=1; }

  # --- the human gate itself ------------------------------------------------
  # With ESC_SELFTEST unset, an agent-context marker must refuse.
  ( ESC_SELFTEST=0 CLAUDECODE=1; esc_ap__require_human >/dev/null 2>&1 )
  [ "$?" -ne 0 ] || { echo "FAIL require_human accepted an agent session"; fail=1; }
  # And a non-TTY stdin must refuse.
  ( ESC_SELFTEST=0; esc_ap__require_human >/dev/null 2>&1 < /dev/null )
  [ "$?" -ne 0 ] || { echo "FAIL require_human accepted a non-TTY stdin"; fail=1; }

  # --- --list ---------------------------------------------------------------
  esc_ap__list >/dev/null 2>&1 || { echo "FAIL list"; fail=1; }

  rm -rf "$root" 2>/dev/null
  unset -f _grep
  if [ "$fail" -eq 0 ]; then echo "approve.sh selftest PASS"; else echo "approve.sh selftest FAIL"; fi
  return "$fail"
}

main() {
  case "${1:---help}" in
    --init-key)               esc_ap__init_key; exit $? ;;
    --postcondition-baseline) esc_ap__baseline; exit $? ;;
    --list)                   esc_ap__list; exit $? ;;
    --disclose)               shift; esc_ap__disclose "${1:-}" "${2:-}"; exit $? ;;
    --selftest)               esc_ap__selftest; exit $? ;;
    --help|-h)                esc_ap__usage; exit 0 ;;
    -*)                       esc_ap__usage; exit 2 ;;
    *)                        esc_ap__approve "${1:-}"; exit $? ;;
  esac
}

main "$@"
