#!/usr/bin/env bash
# =============================================================================
# ratchet - .claude/hooks/escalation-lib.sh
#
# HUMANS: do not hand-edit this file to unblock a run. It is in the CONTROL SET
# (CONTRACT §5.6) and is itself never-escalatable. Changing it changes what an
# approval MEANS.
#
# Contract ............ CONTRACT.md §5.5 (escalation modes), §5.6 (never-
#                       escalatable core), §2.1 (config names), §0 (fail closed)
# Invocation .......... sourced by guard.sh, scope-guard.sh, stop-gate.sh,
#                       escalate.sh, approve.sh; shelled out to by check_done.py
#                       Direct CLI: escalation-lib.sh <verb> [args]  (see usage)
# Blocking mechanism .. NONE directly. This library RETURNS verdicts; the caller
#                       blocks. Every security predicate returns non-zero
#                       (= deny / not-approved) on any error it cannot resolve.
#
# -----------------------------------------------------------------------------
# THE FOUR INVARIANTS. If a change breaks one of these, it is the wrong change.
# -----------------------------------------------------------------------------
# I1. THE AGENT CANNOT PRODUCE AN APPROVAL. An approval is an HMAC-SHA256 over
#     the key at $ESCALATION_KEY. That key is denied to the agent at the
#     settings layer AND at the guard layer, and that deny is itself
#     never-escalatable. Nothing in this file is a secret; the key is. Helper
#     functions here (esc__sign, esc__mac) are deliberately callable -- they are
#     useless without the key, and hiding them would be security theatre that
#     also made this file untestable.
# I2. AN APPROVED RULE DOES NOT SKIP THE OTHER RULES. esc_check_approval answers
#     exactly one question: "has a human signed THIS byte-exact call for THIS
#     ONE rule?" It never answers "is this call safe". Callers MUST evaluate
#     every other rule first and call esc_check_approval last (see esc_peek_
#     approval for the non-consuming ordering probe).
# I3. FAIL CLOSED, INCLUDING ON IGNORANCE. An unknown rule id is never-
#     escalatable. A missing config, a missing hash tool, a missing MAC tool, an
#     unreadable ledger: all deny. There is no warn-and-continue path.
# I4. NOTHING IS RETYPED. The bytes a human reviews are the bytes that were
#     refused, read back from disk. No caller passes a human a summary.
#
# -----------------------------------------------------------------------------
# STATE FILES OWNED BY THIS SCRIPT (§0.7 reader and writer change together)
# All live under $ESCALATIONS_DIR (.pipeline/escalations).
# -----------------------------------------------------------------------------
# <id>.json          THE REFUSAL RECORD. Written once, never rewritten.
#     Flat one-field-per-line JSON. It is read by esc_json_get -- a constrained
#     grep reader, NOT a real parser -- so the format is deliberately narrow:
#       * one "key": "value" pair per line, in a fixed order;
#       * every value is charset-restricted (see esc__field_ok) to
#         [A-Za-z0-9._:/@+-]; no spaces, no quotes, no backslashes, no newlines;
#       * NO FREE TEXT EVER. The agent's justification lives in <id>.why and the
#         refused bytes live in <id>.payload. Putting prose in here would make
#         the narrow reader wrong the first time someone typed a quote.
#     Fields:
#       version      esc/1
#       id           esc-<16 hex>, = sha256(rule|tool|payload)[0:16]
#       rule         rule id (kebab-case)
#       class        never | confirmable  (as classified AT REFUSAL TIME)
#       mode         light | strict       (ESCALATION_MODE at refusal time)
#       tool         Bash | Edit | Write | NotebookEdit | <other>
#       payload_sha  sha256 of the exact refused bytes (<id>.payload)
#       payload_len  byte count of <id>.payload
#       target_sha   for Edit/Write: sha256 of the RESULTING FILE CONTENT.
#                    for every other tool: = payload_sha (so the MAC binds the
#                    exact bytes either way).
#       target_kind  exact | ambiguous | unsupported | nomatch | nofile | plain
#       target_path  repo-relative path for a write, else "-"
#       run_token    16 hex; binds the record to this run (see esc_run_token)
#       recorded_at  epoch seconds
# <id>.payload       THE EXACT REFUSED BYTES, verbatim, no encoding, no newline
#                    added. This is what the human reads in approve.sh.
# <id>.target        For an Edit/Write with target_kind=exact: the exact bytes
#                    the file WOULD contain. Also shown to the human.
# <id>.why           FREE TEXT sidecar: the agent's justification. Never parsed.
# <id>.request       Marker written by escalate.sh: flat json, same reader.
#                    Fields: version,id,rule,tool,requested_at,why_sha
# <id>.approval      Written by approve.sh ONLY. Flat json, same reader.
#                    Fields: version,kind,id,rule,tool,target_sha,run_token,
#                            expiry,signed_at,mac
#                    kind = approval. mac = HMAC over the §5.5 tuple.
# <id>.approval.consumed
#                    The approval file after esc_check_approval renamed it.
#                    Single-use is enforced by that rename FIRST (atomic) and by
#                    the ledger SECOND. Two independent records, because
#                    .pipeline is agent-writable.
# disclosure-<check>-<failhash8>.json
#                    Written by approve.sh --disclose. Fields: version,kind,
#                    check,fail_sha,run_token,expiry,signed_at,mac.
#                    kind = disclosure. expiry = 0 means "no clock, dies at gate
#                    closure only" (§5.5).
# disclosure-<check>-<failhash8>.failure
#                    The verbatim failure text the human ruled on. Reprinted in
#                    FULL by esc_list_disclosures at every subsequent block.
# failures/<check>.txt
#                    The CURRENT verbatim failure text for a check, written by
#                    the gate via esc_record_failure. approve.sh --disclose
#                    reads it so the human signs bytes nobody retyped (I4).
# ledger.jsonl       $ESCALATION_LEDGER. APPEND ONLY. One object per line:
#                    {"ts","event","id","rule","tool","target_sha","run_token",
#                     "mac_sha"}  events: requested consumed rejected disclosed
#                                         signed expire_all postcondition_*
# unclassified-rules.log
#                    Every rule id esc_classify could not classify, one per
#                    line: "<epoch> <rule_id>". A NON-EMPTY FILE FAILS THE
#                    SELFTEST. This is how an unclassified rule surfaces loudly
#                    instead of silently defaulting.
# postcondition-pending
#                    Marker: an approved write under $CLAUDE_DIR happened and
#                    the control-layer selftest has not passed since.
# postcondition-baseline.txt
#                    Sorted failure ids that were ALREADY failing on this host
#                    when a human ran approve.sh --postcondition-baseline. The
#                    floor: current failures must be a subset of these to clear.
# =============================================================================

# ---------------------------------------------------------------------------
# Bootstrap. Sourced OR executed; do not set shell options when sourced.
# ---------------------------------------------------------------------------
ESC_LIB_FILE="${BASH_SOURCE[0]:-$0}"
ESC_LIB_DIR="$(cd "$(dirname "$ESC_LIB_FILE")" 2>/dev/null && pwd || echo .)"

ESC_CONFIG_FALLBACK=0
esc__bootstrap() {
  if [ -r "$ESC_LIB_DIR/ratchet.config.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$ESC_LIB_DIR/ratchet.config.sh" >/dev/null 2>&1 || ESC_CONFIG_FALLBACK=1
  else
    ESC_CONFIG_FALLBACK=1
  fi
  local lib=""
  if [ -n "${HOOKS_DIR:-}" ] && [ -r "${HOOKS_DIR}/hooklib.sh" ]; then
    lib="${HOOKS_DIR}/hooklib.sh"
  elif [ -r "$ESC_LIB_DIR/hooklib.sh" ]; then
    lib="$ESC_LIB_DIR/hooklib.sh"
  fi
  if [ -n "$lib" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$lib" >/dev/null 2>&1 || true
  fi

  # Frozen defaults (CONTRACT §2.1). These are a LAST RESORT so that this file
  # is testable standalone; when ratchet.config.sh is present it has already
  # set every one of them and none of these assignments fire.
  : "${REPO_ROOT:=${CLAUDE_PROJECT_DIR:-$PWD}}"
  : "${RT_VERSION:=0.0.0}"
  : "${ESCALATION_MODE:=light}"
  : "${PIPELINE_DIR:=.pipeline}"
  : "${CONTEXT_DIR:=.context}"
  : "${CLAUDE_DIR:=.claude}"
  : "${HOOKS_DIR:=.claude/hooks}"
  : "${SECRETS_DIR:=secrets}"
  : "${RUN_ACTIVE:=.pipeline/run-active}"
  : "${RUN_START:=.pipeline/run-start}"
  : "${ESCALATIONS_DIR:=.pipeline/escalations}"
  : "${ESCALATION_KEY:=secrets/escalation.key}"
  : "${ESCALATION_TTL_SECONDS:=1800}"
  : "${ESCALATION_LEDGER:=.pipeline/escalations/ledger.jsonl}"
  : "${BASE_BRANCH:=main}"
  : "${DOMAIN_NEVER_ESCALATABLE:=}"
  : "${GOVERNING_CORPUS:=}"
  return 0
}
esc__bootstrap

# Absolute path for a possibly repo-relative config value.
esc__abs() {
  case "$1" in
    /*|[A-Za-z]:[\\/]*) printf '%s' "$1" ;;
    *) printf '%s/%s' "${REPO_ROOT:-$PWD}" "$1" ;;
  esac
}
esc__dir()     { esc__abs "$ESCALATIONS_DIR"; }
esc__ledger()  { esc__abs "$ESCALATION_LEDGER"; }
esc__keypath() { esc__abs "$ESCALATION_KEY"; }
esc__now()     { date -u +%s 2>/dev/null || printf '0'; }
esc__now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
esc__ensure_dir() { mkdir -p "$(esc__dir)" 2>/dev/null || return 1; return 0; }

# Security predicates refuse to answer at all when the control layer did not
# load (I3). The selftest sets ESC_SELFTEST=1 and supplies its own scratch
# config, which is the only sanctioned way past this.
esc__config_ok() {
  [ "$ESC_CONFIG_FALLBACK" -eq 0 ] && return 0
  [ "${ESC_SELFTEST:-0}" = "1" ] && return 0
  printf 'ratchet[escalation]: control-layer config did not load; denying.\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Interpreter probe. Uses rt_pick_py when hooklib is loaded (§4.1); the local
# fallback mirrors it exactly, including skipping the Windows Store stub.
# ---------------------------------------------------------------------------
ESC__PY_CACHE=""
esc__py() {
  if [ -n "$ESC__PY_CACHE" ]; then printf '%s' "$ESC__PY_CACHE"; return 0; fi
  local p=""
  if command -v rt_pick_py >/dev/null 2>&1; then
    p="$(rt_pick_py 2>/dev/null)"
  fi
  if [ -z "$p" ]; then
    local cand v
    for cand in "${RATCHET_PYTHON:-}" python3 python "py -3"; do
      [ -n "$cand" ] || continue
      command -v "${cand%% *}" >/dev/null 2>&1 || continue
      v="$($cand -c "import sys;print(sys.version_info[0])" 2>/dev/null)"
      v="${v//$'\r'/}"
      if [ "$v" = "3" ]; then p="$cand"; break; fi
    done
  fi
  ESC__PY_CACHE="$p"
  printf '%s' "$p"
  [ -n "$p" ]
}

# ---------------------------------------------------------------------------
# Hashing. sha256 of stdin -> lowercase hex. Fails closed (empty + rc1).
# ---------------------------------------------------------------------------
esc__sha256_stdin() {
  local out=""
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  else
    local py; py="$(esc__py)" || { cat >/dev/null; return 1; }
    out="$($py -c 'import sys,hashlib;sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  fi
  out="${out//$'\r'/}"
  case "$out" in
    [0-9a-f]*) [ "${#out}" -eq 64 ] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s' "$out"
}
esc__sha256_str()  { printf '%s' "$1" | esc__sha256_stdin; }
esc__sha256_file() { [ -r "$1" ] || return 1; esc__sha256_stdin < "$1"; }

# ---------------------------------------------------------------------------
# RULE PARTITION  (CONTRACT §5.6)
#
# ESC_NEVER_CORE is the harness-fixed wall. Each entry below maps to a §5.6
# bullet; the mapping is stated so a future reader can check it against the
# contract rather than trust this list.
#
#   secrets / keys / .env  -> secrets-path-access escalation-key-access
#                             dotenv-access secret-in-commit
#   force push             -> force-push
#   push/commit to         -> base-branch-push base-branch-commit
#     BASE_BRANCH outside      ship-consent-missing
#     the ship flow
#   governing corpus       -> governing-corpus-write
#   the control set        -> control-layer-write
#                             approve-script-invocation escalation-state-write
#
# The last two are the control set read for effect rather than by filename
# (§0.4): approve.sh is literally in the frozen control set, so INVOKING it is
# a control-set operation; and an approval means nothing if the agent can edit
# the ledger and the approval files, so $ESCALATIONS_DIR is control-set state.
# Neither widens §5.6 -- both are the same wall seen from the other side.
# dispatch-store-write joins them for the identical reason one level down: the
# glob file IS the scope scope-guard enforces and the baseline IS the evidence
# the SubagentStop gates attribute with, so an agent able to write either one
# authorises its own lane. A scope an agent can widen is not a scope, and no
# approval can coherently lift a rule whose subject is the approval's own scope.
# ---------------------------------------------------------------------------
# THE IDS BELOW ARE THE ONES THE GUARDS ACTUALLY EMIT. guard.sh publishes its
# own list with `guard.sh --list-rules` and the selftest cross-checks every id
# in it against this partition, so a guard that invents a rule id fails the
# control-layer selftest instead of silently getting fail-closed treatment at
# 2am. When adding a rule to a guard, add it HERE in the same commit.
ESC_NEVER_CORE='secrets-access
secrets-path-access
escalation-key-access
dotenv-access
secret-in-commit
force-push
base-branch-push
base-branch-commit
ship-consent-missing
ship-consent-unparsable
governing-corpus-write
control-set-write
control-layer-write
approve-script-invocation
escalation-store-write
escalation-state-write
dispatch-store-write
unparsable-command
unparsable-payload'

# Confirmable in light mode, never in strict mode (§5.5: "the confirmable class
# shrinks and more rules move to never"). A domain that wants any of these to be
# a wall in light mode puts it in DOMAIN_NEVER_ESCALATABLE -- that is what that
# variable is for.
ESC_STRICT_NEVER='forbidden-exec-tokens
forbidden-artifacts
banned-read-files
no-verify-flag
security-boundary-write
test-weakened
test-written-by-developer
network-egress'

# Everything the guards may refuse that a human can lift for ONE byte-exact
# call. This list plus the two above is the COMPLETE known vocabulary; anything
# else is unknown and therefore never (I3).
ESC_CONFIRMABLE_BASE='delete-scope
push-target-unprovable
compound-git-form
git-config-write
git-remote-write
inline-interpreter
gh-verb-off-surface
claude-dir-write
decisions-hot-rollover
manifest-scope-violation
partition-glob-violation
run-lifecycle-file-write
commit-scope-oversize
stop-retry-cap
subagent-retry-cap'

# ---------------------------------------------------------------------------
# THE TWO RESOLVED LISTS. ESC_NEVER_CORE / ESC_STRICT_NEVER / ESC_CONFIRMABLE_BASE
# above are the SOURCES; these two are the ANSWER for the current mode and
# domain pack, and they are what every other builder reads. Recomputed by
# esc_refresh_partition whenever ESCALATION_MODE or DOMAIN_NEVER_ESCALATABLE
# changes, so nothing can read a stale partition.
#   ESC_NEVER       = core + domain + (strict mode ? strict set : nothing)
#   ESC_CONFIRMABLE = base + (light mode ? strict set : nothing)
# Their union is the complete known vocabulary. Anything outside it is unknown
# and therefore never (I3).
# ---------------------------------------------------------------------------
ESC_NEVER=""
ESC_CONFIRMABLE=""
esc_refresh_partition() {
  ESC_NEVER="$ESC_NEVER_CORE"
  if [ -n "${DOMAIN_NEVER_ESCALATABLE:-}" ]; then
    ESC_NEVER="$ESC_NEVER
$DOMAIN_NEVER_ESCALATABLE"
  fi
  if [ "${ESCALATION_MODE:-light}" = "strict" ]; then
    ESC_NEVER="$ESC_NEVER
$ESC_STRICT_NEVER"
    ESC_CONFIRMABLE="$ESC_CONFIRMABLE_BASE"
  else
    ESC_CONFIRMABLE="$ESC_CONFIRMABLE_BASE
$ESC_STRICT_NEVER"
  fi
  export ESC_NEVER ESC_CONFIRMABLE
}

esc__in_list() {  # <needle> <newline-list>
  local needle="$1" line
  [ -n "$needle" ] || return 1
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

esc_rule_id_valid() {  # kebab-case, 2-5 words (§6 naming doctrine)
  case "${1:-}" in
    *[!a-z0-9-]*) return 1 ;;
  esac
  printf '%s' "${1:-}" | grep -Eq '^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$'
}

# The complete known vocabulary, one per line. Guard authors: diff your emitted
# rule ids against this and add anything missing HERE, not in your own file.
esc_rule_vocabulary() {
  printf '%s\n' "$ESC_NEVER_CORE"
  printf '%s\n' "$ESC_STRICT_NEVER"
  printf '%s\n' "$ESC_CONFIRMABLE_BASE"
  if [ -n "${DOMAIN_NEVER_ESCALATABLE:-}" ]; then
    printf '%s\n' "$DOMAIN_NEVER_ESCALATABLE"
  fi
}

esc__report_unknown() {  # <rule_id>
  local log
  printf 'ratchet[escalation]: UNCLASSIFIED RULE ID %s -- treated as NEVER-escalatable (fail closed).\n' "${1:-<empty>}" >&2
  printf '  Add it to ESC_NEVER_CORE, ESC_STRICT_NEVER or ESC_CONFIRMABLE_BASE in escalation-lib.sh.\n' >&2
  esc__ensure_dir || return 0
  log="$(esc__dir)/unclassified-rules.log"
  printf '%s %s\n' "$(esc__now)" "${1:-<empty>}" >> "$log" 2>/dev/null || true
  return 0
}

# esc_classify <rule_id> -> prints never | confirmable | unknown
# An unknown id prints "unknown" AND is logged AND is treated as never by
# esc_is_never_escalatable. Three separate consequences on purpose: the caller
# sees it, the selftest fails on it, and the wall holds meanwhile.
esc_classify() {
  local r="${1:-}"
  r="${r//$'\r'/}"
  esc_refresh_partition
  if esc__in_list "$r" "$ESC_NEVER_CORE"; then printf 'never'; return 0; fi
  if [ -n "${DOMAIN_NEVER_ESCALATABLE:-}" ] && esc__in_list "$r" "$DOMAIN_NEVER_ESCALATABLE"; then
    printf 'never'; return 0
  fi
  if esc__in_list "$r" "$ESC_STRICT_NEVER"; then
    if [ "${ESCALATION_MODE:-light}" = "strict" ]; then printf 'never'; else printf 'confirmable'; fi
    return 0
  fi
  if esc__in_list "$r" "$ESC_CONFIRMABLE_BASE"; then printf 'confirmable'; return 0; fi
  esc__report_unknown "$r"
  printf 'unknown'
  return 0
}

# esc_is_never_escalatable <rule_id> -> 0 (true) if nothing can lift it.
# UNKNOWN COUNTS AS NEVER. That is the whole fail-closed property; do not
# "improve" this by returning 1 for unknown.
esc_is_never_escalatable() {
  local c; c="$(esc_classify "${1:-}" 2>/dev/null)"
  [ "$c" = "confirmable" ] && return 1
  return 0
}

# For the selftest and for other builders' selftests: assert every id given is
# classified (i.e. not unknown). Returns non-zero and names each offender.
esc_assert_classified() {
  local r rc=0 c
  for r in "$@"; do
    c="$(esc_classify "$r" 2>/dev/null)"
    if [ "$c" = "unknown" ]; then printf 'UNCLASSIFIED %s\n' "$r"; rc=1; fi
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Run token. Binds every approval to THIS run: gc-prune.sh archive clears
# RUN_ACTIVE, which changes the token, which invalidates every outstanding
# approval even if esc_expire_all somehow did not run. Two mechanisms, one
# property (§5.5 "bound to this run").
# ---------------------------------------------------------------------------
esc_run_token() {
  local ra="" rs="" f
  f="$(esc__abs "$RUN_ACTIVE")"; [ -r "$f" ] && ra="$(tr -d '\r\n' < "$f" 2>/dev/null)"
  f="$(esc__abs "$RUN_START")";  [ -r "$f" ] && rs="$(tr -d '\r\n' < "$f" 2>/dev/null)"
  [ -n "$ra" ] || ra="no-run"
  [ -n "$rs" ] || rs="0"
  local h; h="$(esc__sha256_str "run|$ra|$rs")" || return 1
  printf '%s' "${h:0:16}"
}

# ---------------------------------------------------------------------------
# HMAC-SHA256. The key is read BY PATH and never appears in argv or the
# environment (§5.5).
#   * python path: the PATH is argv; the key bytes are read by the interpreter.
#   * openssl path: `openssl dgst -hmac K` would put K in argv, which is
#     forbidden, so we build HMAC by hand from the RFC 2104 construction using
#     openssl only as a raw sha256 over FILES. The key bytes live in a shell
#     variable (process memory), never argv, never env, never a temp file.
# The key is required to be hex-ASCII (see esc_key_valid) which keeps the
# ipad/opad blocks NUL-free and makes the hand-rolled path safe in Git-Bash.
# ---------------------------------------------------------------------------
esc_key_valid() {  # <keypath>
  local kp="${1:-$(esc__keypath)}" k
  [ -r "$kp" ] || return 1
  k="$(tr -d ' \t\r\n' < "$kp" 2>/dev/null)"
  [ "${#k}" -ge 32 ] || return 1
  printf '%s' "$k" | grep -Eq '^[0-9a-fA-F]+$'
}

esc__hmac_py() {  # <keypath>; message on stdin
  local py; py="$(esc__py)" || return 1
  "$py" -c '
import sys, hmac, hashlib
with open(sys.argv[1], "rb") as f:
    key = f.read().strip()
msg = sys.stdin.buffer.read()
sys.stdout.write(hmac.new(key, msg, hashlib.sha256).hexdigest())
' "$1" 2>/dev/null
}

esc__hmac_openssl() {  # <keypath>; message on stdin
  command -v openssl >/dev/null 2>&1 || return 1
  local kp="$1" key i b ip="" op="" tmp inner mac
  key="$(tr -d ' \t\r\n' < "$kp" 2>/dev/null)" || return 1
  printf '%s' "$key" | grep -Eq '^[0-9a-fA-F]+$' || return 1   # hex-ASCII only
  [ "${#key}" -le 64 ] || return 1                             # >block: needs a hash step; use python
  i=0
  while [ "$i" -lt 64 ]; do
    if [ "$i" -lt "${#key}" ]; then
      b=$(printf '%d' "'${key:$i:1}")
    else
      b=0
    fi
    ip="$ip$(printf '\\x%02x' $(( b ^ 0x36 )))"
    op="$op$(printf '\\x%02x' $(( b ^ 0x5c )))"
    i=$(( i + 1 ))
  done
  tmp="$(mktemp -d 2>/dev/null)" || return 1
  printf '%b' "$ip" > "$tmp/ipad" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  printf '%b' "$op" > "$tmp/opad" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  cat "$tmp/ipad" - > "$tmp/inner.in" 2>/dev/null
  openssl dgst -sha256 -binary < "$tmp/inner.in" > "$tmp/inner" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  cat "$tmp/opad" "$tmp/inner" > "$tmp/outer.in" 2>/dev/null
  mac="$(openssl dgst -sha256 < "$tmp/outer.in" 2>/dev/null | awk '{print $NF}')"
  rm -rf "$tmp" 2>/dev/null
  mac="${mac//$'\r'/}"
  [ "${#mac}" -eq 64 ] || return 1
  printf '%s' "$mac"
}

# esc__mac <keypath>; message on stdin -> hex mac, or rc1 (never a partial).
esc__mac() {
  local kp="$1" out=""
  [ -r "$kp" ] || { cat >/dev/null; return 1; }
  local tmp; tmp="$(mktemp 2>/dev/null)" || { cat >/dev/null; return 1; }
  cat > "$tmp"
  out="$(esc__hmac_py "$kp" < "$tmp" 2>/dev/null)"
  if [ "${#out}" -ne 64 ]; then
    out="$(esc__hmac_openssl "$kp" < "$tmp" 2>/dev/null)"
  fi
  rm -f "$tmp" 2>/dev/null
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out"
}

# THE SIGNED TUPLE (CONTRACT §5.5, frozen): version|id|rule|tool|target_sha|run_token|expiry
# Byte-exactness comes through TWO of those fields: `id` is derived from the
# refused bytes, and `target_sha` is the resulting file for a write (or the same
# payload hash again for everything else). One changed space -> different id ->
# different tuple -> no approval.
esc__tuple() { printf '%s|%s|%s|%s|%s|%s|%s' "esc/1" "$1" "$2" "$3" "$4" "$5" "$6"; }

# esc__sign <id> <rule> <tool> <target_sha> <run_token> <expiry> -> mac
# Callable by design (I1): worthless without the key.
esc__sign() {
  local kp; kp="$(esc__keypath)"
  esc_key_valid "$kp" || {
    printf 'ratchet[escalation]: key missing or malformed at %s (run approve.sh --init-key).\n' "$kp" >&2
    return 1
  }
  esc__tuple "$1" "$2" "$3" "$4" "$5" "$6" | esc__mac "$kp"
}

# --- Public names for the MAC pair -----------------------------------------
# esc__tuple/esc__mac are internal (double underscore). test_hooks.py, and any
# future auditor, needs to exercise the REAL construction rather than guess at
# it -- a suite that reimplements the MAC proves only that it agrees with
# itself. These two are the same code under stable public names.
#   esc_binding <id> <rule> <tool> <target_sha> <run_token> <expiry> -> the
#     exact signed tuple, frozen by CONTRACT 5.5.
#   esc_hmac <binding> -> hex mac over it with the configured key.
esc_binding() { esc__tuple "$1" "$2" "$3" "$4" "$5" "$6"; }
esc_hmac() {
  local kp; kp="$(esc__keypath)"
  esc_key_valid "$kp" || return 1
  if [ "$#" -gt 0 ]; then printf '%s' "$1" | esc__mac "$kp"; else esc__mac "$kp"; fi
}

# esc__sign_fresh <id> <rule> <tool> <target_sha> <run_token> <base_expiry>
#   Signs, and if that exact signature is already in the ledger (i.e. this call
#   was approved before, in the same second), nudges the expiry forward until
#   the signature is new.
#   Without this, "ask twice" fails on the second ask, because single-use would
#   see the identical MAC and call it a replay. Asking twice is legitimate;
#   replaying is not; this is what tells them apart.
#   PRINTS "<expiry> <mac>" -- the expiry ACTUALLY signed, which the caller must
#   record instead of its own. It prints rather than exporting because callers
#   invoke it in a command substitution, where an assignment would be lost in
#   the subshell.
esc__sign_fresh() {
  local id="$1" rule="$2" tool="$3" tsha="$4" rtok="$5" exp="$6"
  local i=0 mac=""
  while [ "$i" -lt 10 ]; do
    mac="$(esc__sign "$id" "$rule" "$tool" "$tsha" "$rtok" "$exp")" || return 1
    if ! esc__ledger_has_mac "$(esc__sha256_str "$mac")"; then
      printf '%s %s' "$exp" "$mac"
      return 0
    fi
    exp=$(( exp + 1 ))
    i=$(( i + 1 ))
  done
  return 1
}

esc__verify_mac() {  # <mac> <id> <rule> <tool> <target_sha> <run_token> <expiry>
  local want="$1"; shift
  local got; got="$(esc__sign "$@" 2>/dev/null)" || return 1
  [ -n "$want" ] && [ "$want" = "$got" ]
}

# ---------------------------------------------------------------------------
# Flat-JSON writer/reader pair (§0.7). See the format block at the top.
# ---------------------------------------------------------------------------
esc__field_ok() {  # value contains only the narrow charset
  case "${1:-}" in
    "" ) return 1 ;;
    *[!A-Za-z0-9._:/@+-]* ) return 1 ;;
  esac
  return 0
}

# esc__json_write <file> <k1> <v1> <k2> <v2> ...
# Refuses to write a value outside the narrow charset. That refusal is the
# thing that keeps the constrained reader honest.
esc__json_write() {
  local f="$1"; shift
  local tmp="$f.tmp.$$" first=1 k v
  : > "$tmp" || return 1
  printf '{\n' >> "$tmp"
  while [ "$#" -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    if ! esc__field_ok "$v"; then
      printf 'ratchet[escalation]: refusing to write field %s: value outside narrow charset.\n' "$k" >&2
      rm -f "$tmp" 2>/dev/null; return 1
    fi
    [ "$first" -eq 1 ] || printf ',\n' >> "$tmp"
    first=0
    printf '  "%s": "%s"' "$k" "$v" >> "$tmp"
  done
  printf '\n}\n' >> "$tmp"
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# esc_json_get <file> <field> -- the constrained reader. Narrow by contract.
esc_json_get() {
  local f="$1" k="$2" line
  [ -r "$f" ] || return 1
  line="$(grep -m1 "\"$k\": \"" "$f" 2>/dev/null)" || return 1
  line="${line#*\"$k\": \"}"
  line="${line%%\"*}"
  line="${line//$'\r'/}"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

esc__ledger_append() {  # <event> <id> <rule> <tool> <target_sha> <mac_sha>
  local led; led="$(esc__ledger)"
  mkdir -p "$(dirname "$led")" 2>/dev/null || return 1
  # APPEND ONLY. Nothing in the harness ever rewrites or truncates this file.
  printf '{"ts":"%s","event":"%s","id":"%s","rule":"%s","tool":"%s","target_sha":"%s","run_token":"%s","mac_sha":"%s"}\n' \
    "$(esc__now_iso)" "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "$(esc_run_token 2>/dev/null)" "${6:-}" \
    >> "$led" 2>/dev/null || return 1
  return 0
}

esc__ledger_has_consumed() {  # <mac_sha>
  local led; led="$(esc__ledger)"
  [ -r "$led" ] || return 1
  grep -q "\"event\":\"consumed\".*\"mac_sha\":\"$1\"" "$led" 2>/dev/null
}

# esc__ledger_has_mac <mac_sha> -- has this exact signature EVER been issued?
# approve.sh uses this to avoid minting a duplicate. The MAC tuple is frozen at
# seven fields (§5.5) with no nonce, so two approvals for the same call signed
# within the same second would be byte-identical -- and the single-use ledger
# would correctly reject the second as a replay of the first. Bumping the
# expiry by a second makes the second signature distinct without touching the
# frozen tuple. See esc__next_free_expiry.
esc__ledger_has_mac() {
  local led; led="$(esc__ledger)"
  [ -r "$led" ] || return 1
  grep -q "\"mac_sha\":\"$1\"" "$led" 2>/dev/null
}

# ---------------------------------------------------------------------------
# esc_target_sha <tool> <payload_json>
#   Prints:  "<kind> <sha>"  on stdout, where kind is one of
#     exact       -- sha is the sha256 of the RESULTING FILE CONTENT (rc 0)
#     plain       -- not a write tool; sha is "-"                     (rc 4)
#     ambiguous   -- Edit old_string occurs more than once, no replace_all;
#                    there is no single derivable result             (rc 3)
#     nomatch     -- old_string not present                          (rc 5)
#     nofile      -- Edit against a file that does not exist         (rc 6)
#     unsupported -- NotebookEdit / unknown write shape              (rc 7)
#     error       -- could not derive at all                         (rc 1)
#   AMBIGUOUS is distinguishable on purpose: the caller tells the agent to
#   re-issue as Write with the complete content, because an approval that
#   cannot name one resulting file cannot be byte-exact.
#   Optional 3rd arg: a path to write the derived resulting bytes into.
# ---------------------------------------------------------------------------
esc_target_sha() {
  local tool="${1:-}" payload="${2:-}" out="${3:-}"
  case "$tool" in
    Edit|Write|NotebookEdit|MultiEdit) : ;;
    *) printf 'plain -'; return 4 ;;
  esac
  local py script res rc
  py="$(esc__py)" || { printf 'error -'; return 1; }
  script="$(esc__abs "$HOOKS_DIR")/esc_payload.py"
  [ -r "$script" ] || { printf 'error -'; return 1; }
  if [ -n "$out" ]; then
    res="$(printf '%s' "$payload" | "$py" "$script" --tool "$tool" --repo-root "${REPO_ROOT:-$PWD}" --out "$out" 2>/dev/null)"
  else
    res="$(printf '%s' "$payload" | "$py" "$script" --tool "$tool" --repo-root "${REPO_ROOT:-$PWD}" 2>/dev/null)"
  fi
  rc=$?
  res="${res//$'\r'/}"
  case "$rc" in
    0) printf 'exact %s' "$(printf '%s' "$res" | awk '{print $2}')" ;;
    3) printf 'ambiguous -' ;;
    5) printf 'nomatch -' ;;
    6) printf 'nofile -' ;;
    7) printf 'unsupported -' ;;
    *) printf 'error -'; rc=1 ;;
  esac
  return "$rc"
}

esc_target_path() {  # <tool> <payload_json> -> repo-relative path or "-"
  local py script res
  py="$(esc__py)" || { printf '%s' '-'; return 1; }
  script="$(esc__abs "$HOOKS_DIR")/esc_payload.py"
  [ -r "$script" ] || { printf '%s' '-'; return 1; }
  res="$(printf '%s' "${2:-}" | "$py" "$script" --tool "${1:-}" --repo-root "${REPO_ROOT:-$PWD}" --print-path 2>/dev/null)"
  res="${res//$'\r'/}"
  [ -n "$res" ] || res='-'
  printf '%s' "$res"
}

# ---------------------------------------------------------------------------
# esc_record_refusal <rule_id> <tool> <payload> [target_sha]
#   Records the EXACT bytes refused under a content-derived id and prints the
#   id. Idempotent: the same bytes always produce the same id, and an existing
#   record is never rewritten (the record is evidence, not scratch).
#   <payload> may be "-" to read the bytes from stdin, which is how a caller
#   passes a payload too large or too binary for argv.
#   Sets ESC_LAST_ID for the caller.
#
#   [target_sha] -- THE FOURTH ARGUMENT EXISTS BECAUSE OF A REAL MISMATCH.
#   A guard that already knows what an approval would be bound to must say so,
#   because this function cannot always re-derive it. scope-guard.sh checks
#   approvals against sha256(resulting content) but hands this function the
#   repo-relative PATH as the payload; without the fourth argument the record
#   would bind sha256(path), approve.sh would sign that, and the guard would
#   then look for sha256(content) and never find it. The approval would be
#   signed, valid, and permanently unusable -- the worst kind of failure,
#   because every party believes it worked.
#   Pass it whenever the caller computed the sha itself. Omit it and we derive
#   from the payload, which is correct for Bash (bytes are the command) and for
#   a full Edit/Write payload JSON.
# ---------------------------------------------------------------------------
esc_record_refusal() {
  local rule="${1:-}" tool="${2:-}" payload="${3:-}" given_sha="${4:-}"
  esc__config_ok || return 1
  esc_rule_id_valid "$rule" || {
    printf 'ratchet[escalation]: malformed rule id %s\n' "$rule" >&2; return 1; }
  [ -n "$tool" ] || tool="unknown"
  esc__ensure_dir || return 1
  local dir; dir="$(esc__dir)"

  local ptmp; ptmp="$(mktemp 2>/dev/null)" || return 1
  if [ "$payload" = "-" ]; then cat > "$ptmp"; else printf '%s' "$payload" > "$ptmp"; fi

  local psha id
  psha="$(esc__sha256_file "$ptmp")" || { rm -f "$ptmp"; return 1; }
  # id binds rule + tool + the exact bytes.
  id="esc-$(esc__sha256_str "$rule|$tool|$psha" | cut -c1-16)"

  local plen; plen="$(wc -c < "$ptmp" 2>/dev/null | tr -d ' \r')"
  [ -n "$plen" ] || plen=0

  local class mode; class="$(esc_classify "$rule" 2>/dev/null)"
  mode="${ESCALATION_MODE:-light}"

  local tkind tsha tpath tline
  tline="$(esc_target_sha "$tool" "$(cat "$ptmp")" "$dir/$id.target" 2>/dev/null)"
  tkind="$(printf '%s' "$tline" | awk '{print $1}')"
  tsha="$(printf '%s' "$tline" | awk '{print $2}')"
  tpath='-'
  case "$tkind" in
    exact|ambiguous|nomatch|nofile|unsupported)
      tpath="$(esc_target_path "$tool" "$(cat "$ptmp")" 2>/dev/null)" ;;
  esac
  # For a non-write tool the resulting-bytes question is meaningless, so the
  # MAC binds the payload hash itself. Either way the tuple binds real bytes.
  if [ "$tkind" = "plain" ] || [ -z "$tsha" ] || [ "$tsha" = "-" ]; then
    tsha="$psha"
  fi

  # A caller-supplied target sha wins: it is what that guard will actually look
  # for, and a record that binds anything else is a signed approval nobody can
  # use. Validated as a sha256 first -- a malformed value is dropped rather
  # than written, because esc__field_ok would reject it anyway and a half-
  # written record is worse than a derived one.
  case "$given_sha" in
    "") : ;;
    *[!0-9a-fA-F]*) printf 'ratchet[escalation]: ignoring malformed target_sha from caller\n' >&2 ;;
    *) if [ "${#given_sha}" -eq 64 ]; then tsha="$given_sha"; tkind="provided"; fi ;;
  esac
  # A write tool whose result nobody could derive AND nobody supplied: say so
  # explicitly, so escalate.sh sends the agent to Write-with-full-content
  # instead of sending a human on a round trip for an approval that could never
  # be matched.
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      if [ "$tkind" = "error" ] || [ "$tkind" = "plain" ]; then tkind="underivable"; fi ;;
  esac

  local rtok; rtok="$(esc_run_token)" || { rm -f "$ptmp"; return 1; }

  if [ ! -f "$dir/$id.json" ]; then
    cp -f "$ptmp" "$dir/$id.payload" 2>/dev/null || { rm -f "$ptmp"; return 1; }
    esc__json_write "$dir/$id.json" \
      version   "esc/1" \
      id        "$id" \
      rule      "$rule" \
      class     "$class" \
      mode      "$mode" \
      tool      "$tool" \
      payload_sha "$psha" \
      payload_len "$plen" \
      target_sha  "$tsha" \
      target_kind "$tkind" \
      target_path "${tpath:--}" \
      run_token   "$rtok" \
      recorded_at "$(esc__now)" || { rm -f "$ptmp"; return 1; }
    esc__ledger_append "refused" "$id" "$rule" "$tool" "$tsha" "-" || true
  fi
  rm -f "$ptmp" 2>/dev/null
  ESC_LAST_ID="$id"
  printf '%s' "$id"
  return 0
}

# ---------------------------------------------------------------------------
# esc_record_integrity <id>
#
# THE ATTACK THIS CLOSES. Refusal records live under $ESCALATIONS_DIR, which is
# inside $PIPELINE_DIR -- agent scratch. So the bytes approve.sh shows a human
# are, on their own, only as trustworthy as the directory they sit in: an agent
# could get a benign command refused, then rewrite <id>.payload (or <id>.target)
# so the human reads something harmless and signs something else. Invariant I4
# ("nothing is retyped") is worth nothing if the thing not retyped can be
# swapped.
#
# The fix is that the id is a hash of the content, so the record can be
# re-derived rather than trusted:
#     id == sha256(rule | tool | sha256(payload))[0:16]
# Change the payload, the rule or the tool and the id no longer matches its own
# filename. Change the id and it no longer matches the approval the guard will
# check. There is no edit that survives both.
#
# THIS IS NOT A SUBSTITUTE for a guard rule protecting $ESCALATIONS_DIR (rule
# `escalation-state-write`, never-escalatable). It is the second lock: this one
# holds even if the first is missing, and it is the one that protects the
# human's eyes specifically.
#
# Returns 0 if the record is self-consistent; prints what disagreed otherwise.
# ---------------------------------------------------------------------------
esc_record_integrity() {
  local id="${1:-}" dir rec rule tool psha tsha tkind got
  dir="$(esc__dir)"; rec="$dir/$id.json"
  [ -r "$rec" ] || { printf 'no record for %s\n' "$id"; return 1; }
  [ -r "$dir/$id.payload" ] || { printf 'payload sidecar missing for %s\n' "$id"; return 1; }

  rule="$(esc_json_get "$rec" rule)"
  tool="$(esc_json_get "$rec" tool)"
  psha="$(esc_json_get "$rec" payload_sha)"
  tsha="$(esc_json_get "$rec" target_sha)"
  tkind="$(esc_json_get "$rec" target_kind)"

  got="$(esc__sha256_file "$dir/$id.payload")" || { printf 'cannot hash the payload\n'; return 1; }
  if [ "$got" != "$psha" ]; then
    printf 'payload bytes do not match payload_sha (recorded %s, actual %s)\n' "$psha" "$got"
    return 1
  fi
  got="esc-$(esc__sha256_str "$rule|$tool|$psha" | cut -c1-16)"
  if [ "$got" != "$id" ]; then
    printf 'record does not re-derive its own id (filename %s, derived %s): rule/tool/payload were altered\n' "$id" "$got"
    return 1
  fi
  if [ "$tkind" = "plain" ] && [ "$tsha" != "$psha" ]; then
    printf 'non-write record has a target_sha that is not the payload sha\n'
    return 1
  fi
  if [ "$tkind" = "exact" ] && [ -r "$dir/$id.target" ]; then
    got="$(esc__sha256_file "$dir/$id.target")"
    if [ "$got" != "$tsha" ]; then
      printf 'resulting-file bytes do not match target_sha (recorded %s, actual %s)\n' "$tsha" "$got"
      return 1
    fi
  fi
  return 0
}

# The one-line notice a guard prints when it refuses something liftable. The
# exact wording matters: "This refusal is ESCALATABLE" is the string CONTRACT
# §5.5 freezes and the string the agent is trained to look for. A refusal
# WITHOUT it means no approval exists -- do not print it defensively.
esc_refusal_notice() {  # <rule_id> <id>
  local rule="${1:-}" id="${2:-}"
  if esc_is_never_escalatable "$rule"; then
    printf 'This refusal is NOT escalatable (rule=%s). No approval exists that lifts it -- not a human'"'"'s, not one signed by mistake.\n' "$rule"
    printf 'Use the Hard Stop flow: write the Decision Card, commit WIP, stop cleanly. Do not look for another route.\n'
  else
    printf 'This refusal is ESCALATABLE (id=%s)\n' "$id"
    printf 'If this specific call is justified: %s/escalate.sh request %s "<why this specific call>"\n' "$HOOKS_DIR" "$id"
  fi
}

# ---------------------------------------------------------------------------
# esc_peek_approval / esc_check_approval
#
# ORDERING CONTRACT FOR GUARD AUTHORS (this is I2 made operational):
#   1. evaluate every other rule first;
#   2. if the ONLY thing left is one confirmable rule, call esc_check_approval;
#   3. never call it "just to see" -- it CONSUMES. Use esc_peek_approval for
#      that. Consuming an approval on a call you then block for another reason
#      burns the human's signature for nothing.
# ---------------------------------------------------------------------------
esc__approval_fields_ok() {  # <file> <id> <rule> <tool> <target_sha>; sets ESC__A_*
  local f="$1"
  ESC__A_ID="$(esc_json_get "$f" id 2>/dev/null)"
  ESC__A_RULE="$(esc_json_get "$f" rule 2>/dev/null)"
  ESC__A_TOOL="$(esc_json_get "$f" tool 2>/dev/null)"
  ESC__A_TSHA="$(esc_json_get "$f" target_sha 2>/dev/null)"
  ESC__A_RTOK="$(esc_json_get "$f" run_token 2>/dev/null)"
  ESC__A_EXP="$(esc_json_get "$f" expiry 2>/dev/null)"
  ESC__A_MAC="$(esc_json_get "$f" mac 2>/dev/null)"
  ESC__A_KIND="$(esc_json_get "$f" kind 2>/dev/null)"
  [ "$ESC__A_KIND" = "approval" ] || return 1
  [ "$ESC__A_ID" = "$2" ] || return 1
  [ "$ESC__A_RULE" = "$3" ] || return 1
  [ "$ESC__A_TOOL" = "$4" ] || return 1
  [ "$ESC__A_TSHA" = "$5" ] || return 1
  return 0
}

esc__approval_valid() {  # <id> <rule> <tool> <target_sha> -> 0 if usable now
  local id="$1" rule="$2" tool="$3" tsha="$4" f now rtok
  f="$(esc__dir)/$id.approval"
  [ -r "$f" ] || { ESC__A_WHY="no approval on disk for $id"; return 1; }
  esc__approval_fields_ok "$f" "$id" "$rule" "$tool" "$tsha" || {
    ESC__A_WHY="approval does not match this call (rule/tool/bytes differ)"; return 1; }
  # An approval never lifts a never-escalatable rule, even if one exists on
  # disk. Belt and braces: approve.sh refuses to sign these, and this refuses
  # to honour one if a signed file somehow appears.
  if esc_is_never_escalatable "$rule"; then
    ESC__A_WHY="rule $rule is never-escalatable; no approval is honoured"; return 1; fi
  now="$(esc__now)"
  case "$ESC__A_EXP" in ''|*[!0-9]*) ESC__A_WHY="malformed expiry"; return 1 ;; esac
  if [ "$ESC__A_EXP" -le "$now" ]; then ESC__A_WHY="approval expired at $ESC__A_EXP (now $now)"; return 1; fi
  rtok="$(esc_run_token)" || { ESC__A_WHY="cannot derive run token"; return 1; }
  [ "$ESC__A_RTOK" = "$rtok" ] || { ESC__A_WHY="approval belongs to a different run"; return 1; }
  local macsha; macsha="$(esc__sha256_str "$ESC__A_MAC")" || { ESC__A_WHY="hash tool unavailable"; return 1; }
  if esc__ledger_has_consumed "$macsha"; then
    ESC__A_WHY="approval already consumed (single-use)"; return 1; fi
  esc__verify_mac "$ESC__A_MAC" "$id" "$rule" "$tool" "$tsha" "$rtok" "$ESC__A_EXP" || {
    ESC__A_WHY="MAC does not verify"; return 1; }
  ESC__A_MACSHA="$macsha"
  ESC__A_WHY="ok"
  return 0
}

# esc__resolve_id <rule> <tool> <target_sha> [id]
#   Callers reach esc_check_approval by two different routes and only one of
#   them knows the id:
#     * scope-guard records the refusal first, so ESC_LAST_ID is set;
#     * guard.sh checks for an approval BEFORE recording anything, because on
#       the approved re-issue there is nothing to record -- so it has no id at
#       all, only (rule, tool, sha-of-the-command-bytes).
#   Requiring an id here would silently break the second route: every approval
#   would verify in testing and never be found in production. So we resolve it,
#   in this order:
#     1. the explicit argument / $ESC_APPROVAL_ID / $ESC_LAST_ID;
#     2. the derivation, which is exact for non-write tools because their
#        target_sha IS their payload_sha (see esc_record_refusal);
#     3. a scan of the approvals on disk for one whose rule+tool+target_sha
#        match -- the general case, which also covers writes.
#   Resolution never weakens anything: whatever id comes out still has to pass
#   the full MAC, TTL, run-binding, single-use and class checks.
esc__resolve_id() {
  local rule="$1" tool="$2" tsha="$3" id="${4:-}"
  [ -n "$id" ] || id="${ESC_APPROVAL_ID:-${ESC_LAST_ID:-}}"
  if [ -n "$id" ] && [ -r "$(esc__dir)/$id.approval" ]; then printf '%s' "$id"; return 0; fi

  local derived; derived="esc-$(esc__sha256_str "$rule|$tool|$tsha" 2>/dev/null | cut -c1-16)"
  if [ -r "$(esc__dir)/$derived.approval" ]; then printf '%s' "$derived"; return 0; fi

  local f base
  for f in "$(esc__dir)"/*.approval; do
    [ -r "$f" ] || continue
    [ "$(esc_json_get "$f" rule 2>/dev/null)" = "$rule" ] || continue
    [ "$(esc_json_get "$f" tool 2>/dev/null)" = "$tool" ] || continue
    [ "$(esc_json_get "$f" target_sha 2>/dev/null)" = "$tsha" ] || continue
    base="${f##*/}"
    printf '%s' "${base%.approval}"
    return 0
  done
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  return 1
}

esc_peek_approval() {  # <rule> <tool> <target_sha> [id] -- verifies, does NOT consume
  esc__config_ok || return 1
  local id; id="$(esc__resolve_id "$1" "$2" "$3" "${4:-}")" || return 1
  [ -n "$id" ] || return 1
  esc__approval_valid "$id" "$1" "$2" "$3"
}

# esc_check_approval <rule_id> <tool> <target_sha> [id]
#   Returns 0 ONLY for a valid, unexpired, unconsumed, run-matching,
#   byte-matching, correctly-MACed approval for a confirmable rule -- and
#   CONSUMES it in the same breath.
#   [id] defaults to $ESC_APPROVAL_ID, then to $ESC_LAST_ID (set by the
#   esc_record_refusal the guard just performed on the re-issued call).
esc_check_approval() {
  esc__config_ok || return 1
  local rule="${1:-}" tool="${2:-}" tsha="${3:-}" id
  ESC__A_WHY="no approval matches this call"
  id="$(esc__resolve_id "$rule" "$tool" "$tsha" "${4:-}")" || return 1
  [ -n "$id" ] || return 1
  if ! esc__approval_valid "$id" "$rule" "$tool" "$tsha"; then
    esc__ledger_append "rejected" "$id" "$rule" "$tool" "$tsha" "-" || true
    return 1
  fi
  # CONSUME. The atomic rename happens FIRST: if two guards race, exactly one
  # wins the rename and the loser sees no approval file. The ledger append is
  # the durable record, but the rename is what makes single-use atomic.
  local dir; dir="$(esc__dir)"
  if ! mv -f "$dir/$id.approval" "$dir/$id.approval.consumed" 2>/dev/null; then
    ESC__A_WHY="could not consume approval (rename failed)"
    return 1
  fi
  esc__ledger_append "consumed" "$id" "$rule" "$tool" "$tsha" "$ESC__A_MACSHA" || true
  return 0
}

esc_approval_reason() { printf '%s' "${ESC__A_WHY:-unknown}"; }

# ---------------------------------------------------------------------------
# DISCLOSURES (§5.5)
# A disclosure never means "this check passes". It means: a human read this
# exact failure text and ruled the run may ship with it DISCLOSED. It binds to
# the FAILURE TEXT, so a different failure of the same check is undisclosed and
# blocks. It is not single-use -- the Stop gate reprints it at every block.
# ---------------------------------------------------------------------------
esc__norm_failure() {  # stdin -> normalized failure text on stdout
  # Minimal on purpose. Anything cleverer would let a materially different
  # failure match a disclosure. We strip only what a terminal added:
  # CR, ANSI SGR sequences, trailing spaces, and leading/trailing blank lines.
  local esc_ch; esc_ch="$(printf '\033')"
  sed -e 's/\r$//' -e "s/${esc_ch}\[[0-9;]*[A-Za-z]//g" -e 's/[[:space:]]*$//' 2>/dev/null \
    | sed -e '/./,$!d' 2>/dev/null \
    | awk '{ lines[NR]=$0 } END { last=0; for(i=1;i<=NR;i++) if(lines[i]!="") last=i; for(i=1;i<=last;i++) print lines[i] }'
}

esc__fail_sha() {  # <check_id> ; failure text on stdin
  local n; n="$(esc__norm_failure)"
  printf '%s' "check:$1
$n" | esc__sha256_stdin
}

esc_check_id_valid() {
  printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

# esc_record_failure <check_id> <text|->  -- called by the gate when a check
# fails, so approve.sh --disclose can show the human bytes nobody retyped (I4).
esc_record_failure() {
  local c="${1:-}" t="${2:-}"
  esc_check_id_valid "$c" || return 1
  esc__ensure_dir || return 1
  mkdir -p "$(esc__dir)/failures" 2>/dev/null || return 1
  # VERBATIM, with no trailing newline added. check_done.py hashes the exact
  # detail string it renders and asks rt_esc_disclosed about that sha, so a
  # newline this function helpfully appended would make every disclosure fail
  # to match while looking perfectly correct on screen.
  if [ "$t" = "-" ]; then cat > "$(esc__dir)/failures/$c.txt"
  else printf '%s' "$t" > "$(esc__dir)/failures/$c.txt"; fi
}

# esc_failure_raw_sha <check_id> -- sha256 of the recorded failure bytes,
# exactly as check_done.py would compute it over the same string.
esc_failure_raw_sha() {
  local f; f="$(esc__dir)/failures/${1:-}.txt"
  [ -r "$f" ] || return 1
  esc__sha256_file "$f"
}

# esc_disclose_verify <check_id> <failure_text|->
#   0 = an active disclosure covers exactly this failure text.
esc_disclose_verify() {
  esc__config_ok || return 1
  local c="${1:-}" t="${2:-}" fsha f rtok exp mac
  esc_check_id_valid "$c" || return 1
  if [ "$t" = "-" ]; then fsha="$(esc__fail_sha "$c")"; else fsha="$(printf '%s' "$t" | esc__fail_sha "$c")"; fi
  [ -n "$fsha" ] || return 1
  f="$(esc__dir)/disclosure-$c-${fsha:0:8}.json"
  [ -r "$f" ] || return 1
  [ "$(esc_json_get "$f" kind 2>/dev/null)" = "disclosure" ] || return 1
  [ "$(esc_json_get "$f" check 2>/dev/null)" = "$c" ] || return 1
  [ "$(esc_json_get "$f" fail_sha 2>/dev/null)" = "$fsha" ] || return 1
  rtok="$(esc_run_token)" || return 1
  [ "$(esc_json_get "$f" run_token 2>/dev/null)" = "$rtok" ] || return 1
  exp="$(esc_json_get "$f" expiry 2>/dev/null)"
  case "$exp" in ''|*[!0-9]*) return 1 ;; esac
  # expiry 0 = no clock; a disclosure dies at gate closure, not on a timer.
  if [ "$exp" -ne 0 ] && [ "$exp" -le "$(esc__now)" ]; then return 1; fi
  mac="$(esc_json_get "$f" mac 2>/dev/null)"
  esc__verify_mac "$mac" "disclose-$c" "disclosure" "$c" "$fsha" "$rtok" "$exp"
}

# esc_list_disclosures -- prints every active disclosure IN FULL. The Stop gate
# calls this at every block. Nothing is summarised: the point is that a
# disclosed red stays visible forever, it just stops being re-litigated.
esc_list_disclosures() {
  local dir f c fsha rtok n=0
  dir="$(esc__dir)"
  [ -d "$dir" ] || return 0
  rtok="$(esc_run_token 2>/dev/null)"
  for f in "$dir"/disclosure-*.json; do
    [ -r "$f" ] || continue
    [ "$(esc_json_get "$f" kind 2>/dev/null)" = "disclosure" ] || continue
    [ "$(esc_json_get "$f" run_token 2>/dev/null)" = "$rtok" ] || continue
    c="$(esc_json_get "$f" check 2>/dev/null)"
    fsha="$(esc_json_get "$f" fail_sha 2>/dev/null)"
    n=$(( n + 1 ))
    if [ "$n" -eq 1 ]; then
      printf '=== DISCLOSED REDS (a human ruled the run may ship with these) ===\n'
      printf 'DISCLOSED is not PASS. Each is excluded from the exit code only.\n\n'
    fi
    printf -- '--- check: %s   signed: %s   failure-sha: %s\n' \
      "$c" "$(esc_json_get "$f" signed_at 2>/dev/null)" "$fsha"
    if [ -r "${f%.json}.failure" ]; then
      # The failure file is stored WITHOUT a trailing newline so its sha matches
      # what check_done.py hashes. Add one for display only, and only when it is
      # missing, or the footer runs into the last line of the failure.
      cat "${f%.json}.failure"
      [ -n "$(tail -c 1 "${f%.json}.failure" 2>/dev/null)" ] && printf '\n'
    else
      printf '(failure text sidecar missing -- this disclosure will not verify)\n'
    fi
    printf -- '--- end %s\n\n' "$c"
  done
  [ "$n" -gt 0 ] && printf '=== %d disclosed red(s) ===\n' "$n"
  return 0
}

esc_disclosure_count() {
  local dir f rtok n=0
  dir="$(esc__dir)"; [ -d "$dir" ] || { printf '0'; return 0; }
  rtok="$(esc_run_token 2>/dev/null)"
  for f in "$dir"/disclosure-*.json; do
    [ -r "$f" ] || continue
    [ "$(esc_json_get "$f" run_token 2>/dev/null)" = "$rtok" ] && n=$(( n + 1 ))
  done
  printf '%d' "$n"
}

# ---------------------------------------------------------------------------
# CONTROL-LAYER POSTCONDITION
#
# Rule: after any APPROVED write under $CLAUDE_DIR, the control-layer selftest
# must run and pass before the next tool call is permitted. An approved edit
# that breaks the guards is the one state where no later refusal can be
# trusted.
#
# THE TRAP THIS AVOIDS: a marker that refuses the very command that would clear
# it. esc_postcondition_is_remedy exists so the guards can let the remedy
# through, and esc_postcondition_remedy_cmd prints it verbatim in the refusal
# message. The remedy is on escalate.sh (an allow-listed agent-invocable
# script, CONTRACT §3) and NOT on approve.sh, which the agent may never run.
# ---------------------------------------------------------------------------
esc__pc_marker()   { printf '%s/postcondition-pending' "$(esc__dir)"; }
esc__pc_baseline() { printf '%s/postcondition-baseline.txt' "$(esc__dir)"; }

esc_postcondition_arm() {  # <reason>
  esc__ensure_dir || return 1
  printf 'armed_at=%s\nreason=%s\nremedy=%s\n' \
    "$(esc__now_iso)" "${1:-approved-write-under-control-layer}" "$(esc_postcondition_remedy_cmd)" \
    > "$(esc__pc_marker)" 2>/dev/null || return 1
  esc__ledger_append "postcondition_armed" "-" "control-layer-write" "-" "-" "-" || true
  return 0
}

esc_postcondition_pending() { [ -f "$(esc__pc_marker)" ]; }

esc_postcondition_remedy_cmd() {
  printf 'bash %s/escalate.sh postcondition-clear' "$HOOKS_DIR"
}

# esc_postcondition_is_remedy <command-string>
# Must stay generous: a marker whose remedy is unreachable wedges the run
# permanently, which is a worse failure than briefly allowing a diagnostic.
# Everything allowed here is read-only or is the clear path itself.
esc_postcondition_is_remedy() {
  local c="${1:-}"
  case "$c" in
    *escalate.sh*postcondition-clear*)  return 0 ;;
    *escalate.sh*postcondition-status*) return 0 ;;
    *escalation-lib.sh*postcondition*)  return 0 ;;
    *test_hooks.py*)                    return 0 ;;
    *--selftest*)                       return 0 ;;
  esac
  return 1
}

# The control-layer selftest. Prints one "FAIL <name>" line per failure on
# stdout; rc 0 = clean. Overridable with RATCHET_CONTROL_SELFTEST for hosts
# with their own runner.
#
# EVERY COMPONENT RUNS UNDER A TIMEOUT, WITH STDIN CLOSED. This is not defensive
# padding -- it is what keeps the postcondition remedy reachable. The marker
# refuses the next tool call until this function returns; a component that
# blocks on stdin or loops forever would wedge the run with no way out, which
# is precisely the trap the postcondition rule is supposed to avoid. A hang is
# therefore reported as a FAILURE of that component (loud, nameable, fixable)
# rather than allowed to become a hang of the harness.
# ESC_SELFTEST_TIMEOUT bounds each component; the full-suite runner
# (test_hooks.py) gets its own, larger bound.
esc_control_selftest() {
  local hd py rc=0 s out t tt
  hd="$(esc__abs "$HOOKS_DIR")"
  t="${ESC_SELFTEST_TIMEOUT:-60}"
  tt="${ESC_SUITE_TIMEOUT:-600}"

  # Run one component with stdin closed and a wall-clock bound.
  # Prints "FAIL <name>" (with "(timed out)" when that is why) and returns 1.
  _esc_run_component() {  # <name> <seconds> <cmd...>
    local nm="$1" secs="$2"; shift 2
    local o crc
    if command -v timeout >/dev/null 2>&1; then
      o="$(timeout "$secs" "$@" 2>&1 </dev/null)"; crc=$?
    else
      o="$("$@" 2>&1 </dev/null)"; crc=$?
    fi
    if [ "$crc" -eq 124 ] || [ "$crc" -eq 137 ]; then
      printf 'FAIL %s (timed out after %ss)\n' "$nm" "$secs"; return 1
    fi
    [ "$crc" -eq 0 ] && return 0
    printf 'FAIL %s\n' "$nm"
    return 1
  }

  if [ -n "${RATCHET_CONTROL_SELFTEST:-}" ]; then
    if command -v timeout >/dev/null 2>&1; then
      out="$(cd "${REPO_ROOT:-$PWD}" && timeout "$tt" bash -c "$RATCHET_CONTROL_SELFTEST" 2>&1 </dev/null)" || rc=1
    else
      out="$(cd "${REPO_ROOT:-$PWD}" && bash -c "$RATCHET_CONTROL_SELFTEST" 2>&1 </dev/null)" || rc=1
    fi
    [ "$rc" -eq 0 ] || printf 'FAIL custom-control-selftest\n'
    unset -f _esc_run_component
    return "$rc"
  fi

  py="$(esc__py 2>/dev/null)"
  if [ -n "$py" ] && [ -r "$hd/test_hooks.py" ]; then
    _esc_run_component "test_hooks.py" "$tt" "$py" "$hd/test_hooks.py" || rc=1
  fi
  for s in guard.sh scope-guard.sh stop-gate.sh subagent-gate.sh red-gate.sh \
           escalation-lib.sh escalate.sh approve.sh hooklib.sh; do
    [ -r "$hd/$s" ] || continue
    grep -q -- '--selftest' "$hd/$s" 2>/dev/null || continue
    _esc_run_component "$s" "$t" bash "$hd/$s" --selftest || rc=1
  done
  if [ -n "$py" ]; then
    for s in esc_payload.py check_done.py check_narrative.py; do
      [ -r "$hd/$s" ] || continue
      grep -q -- '--selftest' "$hd/$s" 2>/dev/null || continue
      _esc_run_component "$s" "$t" "$py" "$hd/$s" --selftest || rc=1
    done
  fi
  unset -f _esc_run_component
  return "$rc"
}

esc_postcondition_baseline_write() {
  esc__ensure_dir || return 1
  esc_control_selftest 2>/dev/null | sort -u > "$(esc__pc_baseline)" 2>/dev/null || true
  printf 'baseline recorded: %s failing item(s) in %s\n' \
    "$(wc -l < "$(esc__pc_baseline)" 2>/dev/null | tr -d ' ')" "$(esc__pc_baseline)"
  return 0
}

# esc_postcondition_clear -- runs the selftest and clears the marker only if the
# current failure set is a SUBSET of the recorded baseline (so a host with
# pre-existing failures has a floor and is not wedged forever).
esc_postcondition_clear() {
  esc__ensure_dir || return 1
  local cur base extra
  cur="$(mktemp)" || return 1
  esc_control_selftest > "$cur" 2>/dev/null
  sort -u -o "$cur" "$cur" 2>/dev/null
  base="$(esc__pc_baseline)"
  [ -r "$base" ] || : > "$base"
  extra="$(comm -23 "$cur" <(sort -u "$base" 2>/dev/null) 2>/dev/null)"
  rm -f "$cur" 2>/dev/null
  if [ -n "$extra" ]; then
    printf 'control-layer selftest FAILED with failures not in the baseline:\n%s\n' "$extra"
    printf 'The control layer is not green. Fix it, or have a human re-baseline with:\n' >&2
    printf '  bash %s/approve.sh --postcondition-baseline\n' "$HOOKS_DIR" >&2
    esc__ledger_append "postcondition_failed" "-" "control-layer-write" "-" "-" "-" || true
    return 1
  fi
  rm -f "$(esc__pc_marker)" 2>/dev/null
  esc__ledger_append "postcondition_cleared" "-" "control-layer-write" "-" "-" "-" || true
  printf 'control-layer selftest green; postcondition cleared.\n'
  return 0
}

# ---------------------------------------------------------------------------
# esc_expire_all -- called by gc-prune.sh archive (§5.1). Every approval and
# every disclosure dies at gate closure.
# The postcondition marker is DELIBERATELY NOT cleared here: a broken control
# layer must survive the end of a run. Clearing it would hide exactly the state
# it exists to make visible.
# ---------------------------------------------------------------------------
esc_expire_all() {
  local dir f n=0
  dir="$(esc__dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.approval "$dir"/disclosure-*.json "$dir"/disclosure-*.failure "$dir"/*.request; do
    [ -e "$f" ] || continue
    rm -f "$f" 2>/dev/null && n=$(( n + 1 ))
  done
  esc__ledger_append "expire_all" "-" "-" "-" "-" "-" || true
  printf 'escalation: expired %d approval/disclosure artifact(s).\n' "$n"
  if esc_postcondition_pending; then
    printf 'NOTICE: a control-layer postcondition is still PENDING and survives gate closure.\n' >&2
    printf '        Remedy: %s\n' "$(esc_postcondition_remedy_cmd)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ADAPTER SURFACE for check_done.py (§3: it shells out rather than
# re-implementing the HMAC or the rule sets). check_done.py sources this file
# and probes for these exact names; a missing name is rc 8 on its side and it
# fails closed -- nothing is disclosed, nothing is treated as escalatable.
# Keep the names AND the argument shapes; they are check_done.py's contract.
# ---------------------------------------------------------------------------

# rt_esc_disclosed <check-name> <sha256 of the RAW failure text>
#   check_done.py hashes the exact detail string it is about to render and asks
#   whether a human disclosed that. It does NOT know about our canonical
#   normalised hash, so disclosures also record the raw sha and we match on
#   either -- then verify the MAC over the canonical one regardless. Matching
#   is a lookup; the signature is still what authorises.
rt_esc_disclosed() {
  esc__config_ok || return 1
  local check="${1:-}" raw="${2:-}" f rtok
  esc_check_id_valid "$check" || return 1
  case "$raw" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  rtok="$(esc_run_token 2>/dev/null)" || return 1
  for f in "$(esc__dir)"/disclosure-"$check"-*.json; do
    [ -r "$f" ] || continue
    [ "$(esc_json_get "$f" kind 2>/dev/null)" = "disclosure" ] || continue
    [ "$(esc_json_get "$f" check 2>/dev/null)" = "$check" ] || continue
    [ "$(esc_json_get "$f" run_token 2>/dev/null)" = "$rtok" ] || continue
    if [ "$(esc_json_get "$f" raw_sha 2>/dev/null)" = "$raw" ] \
    || [ "$(esc_json_get "$f" fail_sha 2>/dev/null)" = "$raw" ]; then
      # Found a candidate by hash; now make it earn it.
      [ -r "${f%.json}.failure" ] || continue
      esc_disclose_verify "$check" - < "${f%.json}.failure" && return 0
    fi
  done
  return 1
}

rt_esc_never_escalatable() { esc_is_never_escalatable "${1:-}"; }
rt_esc_never_list()        { esc_refresh_partition; printf '%s\n' "$ESC_NEVER"; }
rt_esc_confirmable_list()  { esc_refresh_partition; printf '%s\n' "$ESC_CONFIRMABLE"; }
rt_esc_classify()          { esc_classify "${1:-}"; }
# Aliases test_hooks.py probes for when esc_classify is absent. Cheap, and they
# keep an older or newer sibling from silently falling through to UNKNOWN.
esc_never_escalatable()    { esc_is_never_escalatable "${1:-}"; }
esc_escalatable()          { [ "$(esc_classify "${1:-}" 2>/dev/null)" = "confirmable" ]; }

# ---------------------------------------------------------------------------
# Small helpers other control-layer files call.
# ---------------------------------------------------------------------------
# esc_cmd_invokes_approve <command-string> -- decide by EFFECT (§0.4), not by a
# verb allowlist: bash/sh/source/./env/exec wrappers, any path form, any
# extension-less alias that still names the file.
esc_cmd_invokes_approve() {
  case "${1:-}" in
    *approve.sh*) return 0 ;;
  esac
  return 1
}

# esc_path_is_key_or_secrets <path> -- the deny that must never be liftable.
esc_path_is_key_or_secrets() {
  local p="${1:-}"
  p="${p//\\//}"
  p="${p//$'\r'/}"
  case "$p" in
    */"${SECRETS_DIR#./}"|*"/${SECRETS_DIR#./}/"*|"${SECRETS_DIR#./}"|"${SECRETS_DIR#./}/"*) return 0 ;;
    *"${ESCALATION_KEY#./}"*) return 0 ;;
  esac
  return 1
}

esc_mode() { printf '%s' "${ESCALATION_MODE:-light}"; }

# ---------------------------------------------------------------------------
# CLI (direct execution only). Verbs mirror the functions so that non-shell
# callers -- check_done.py in particular -- can shell out.
# ---------------------------------------------------------------------------
esc__usage() {
  cat <<'USAGE'
escalation-lib.sh -- Ratchet escalation subsystem (library + small CLI)

  classify <rule-id>                 print never|confirmable|unknown
  is-never <rule-id>                 exit 0 if nothing can lift it
  vocabulary                         print the complete known rule vocabulary
  run-token                          print this run's binding token
  record <rule-id> <tool> <payload|-> record a refusal, print its id
  notice <rule-id> <id>              print the guard's refusal notice
  integrity <id>                     re-derive a refusal record from its bytes
  peek <rule> <tool> <target-sha> <id>   verify WITHOUT consuming
  check <rule> <tool> <target-sha> <id>  verify AND consume (exit 0 = permitted)
  target-sha <tool> <payload-json>   print "<kind> <sha>"
  disclose-verify <check-id> <text|-> exit 0 if disclosed
  list-disclosures                   print every active disclosure in full
  disclosure-count                   print the number of active disclosures
  record-failure <check-id> <text|->  store a check's verbatim failure text
  postcondition-status               exit 0 if a postcondition is pending
  postcondition-clear                run the control selftest and clear
  expire-all                         gate closure: kill approvals + disclosures
  --selftest                         run the built-in test suite
USAGE
}

esc__selftest() {
  # Everything below runs in a scratch repo with a scratch key. It never reads
  # the real key and never touches the real .pipeline.
  local fail=0 root
  root="$(mktemp -d)" || { echo "FAIL mktemp"; return 1; }

  ESC_SELFTEST=1
  REPO_ROOT="$root"
  ESCALATIONS_DIR="$root/.pipeline/escalations"
  ESCALATION_LEDGER="$root/.pipeline/escalations/ledger.jsonl"
  ESCALATION_KEY="$root/secrets/escalation.key"
  RUN_ACTIVE="$root/.pipeline/run-active"
  RUN_START="$root/.pipeline/run-start"
  HOOKS_DIR="$ESC_LIB_DIR"
  ESCALATION_TTL_SECONDS=1800
  ESCALATION_MODE=light
  DOMAIN_NEVER_ESCALATABLE=""
  mkdir -p "$root/.pipeline/escalations" "$root/secrets" "$root/src"
  printf '%s\n' "M1" > "$RUN_ACTIVE"
  printf '%s\n' "1700000000" > "$RUN_START"
  printf '%s\n' "$(openssl rand -hex 32 2>/dev/null || echo aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899)" > "$ESCALATION_KEY"
  chmod 600 "$ESCALATION_KEY" 2>/dev/null

  _t() { # <name> <expected-rc> <cmd...>
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -ne "$want" ]; then echo "FAIL $name (rc=$rc want=$want)"; fail=1; fi
  }
  # Capture-then-grep, never `cmd | grep -q`: under `set -o pipefail` grep -q
  # closes the pipe early, the writer takes SIGPIPE, and the pipeline reports
  # failure for a test that actually passed. This bit the suite once already.
  _grep() { # <name> <pattern> <cmd...>
    local name="$1" pat="$2"; shift 2
    local out; out="$(mktemp)"
    "$@" > "$out" 2>&1
    if ! grep -q -- "$pat" "$out"; then
      echo "FAIL $name (pattern not found: $pat)"; fail=1
    fi
    rm -f "$out"
  }

  # --- rule partition -------------------------------------------------------
  [ "$(esc_classify force-push)" = "never" ] || { echo "FAIL classify force-push"; fail=1; }
  [ "$(esc_classify control-layer-write)" = "never" ] || { echo "FAIL classify control-layer-write"; fail=1; }
  [ "$(esc_classify delete-scope)" = "confirmable" ] || { echo "FAIL classify delete-scope"; fail=1; }
  [ "$(esc_classify totally-made-up-rule 2>/dev/null)" = "unknown" ] || { echo "FAIL classify unknown"; fail=1; }
  _t "is-never unknown fails closed" 0 esc_is_never_escalatable totally-made-up-rule
  _t "is-never confirmable" 1 esc_is_never_escalatable delete-scope
  # the unknown above must have been logged loudly
  [ -s "$ESCALATIONS_DIR/unclassified-rules.log" ] || { echo "FAIL unknown rule not logged"; fail=1; }
  rm -f "$ESCALATIONS_DIR/unclassified-rules.log"
  # strict mode moves the strict set to never
  ESCALATION_MODE=strict
  [ "$(esc_classify test-weakened)" = "never" ] || { echo "FAIL strict mode"; fail=1; }
  ESCALATION_MODE=light
  [ "$(esc_classify test-weakened)" = "confirmable" ] || { echo "FAIL light mode"; fail=1; }
  # domain additions are honoured
  DOMAIN_NEVER_ESCALATABLE='delete-scope'
  [ "$(esc_classify delete-scope)" = "never" ] || { echo "FAIL domain never list"; fail=1; }
  DOMAIN_NEVER_ESCALATABLE=""
  # every id in the vocabulary classifies
  local v
  v="$(esc_rule_vocabulary | tr '\n' ' ')"
  # shellcheck disable=SC2086
  if ! esc_assert_classified $v >/dev/null 2>&1; then echo "FAIL vocabulary self-classification"; fail=1; fi
  rm -f "$ESCALATIONS_DIR/unclassified-rules.log" 2>/dev/null

  # --- hashing + hmac agreement --------------------------------------------
  local m1 m2
  m1="$(printf 'the message' | esc__hmac_py "$ESCALATION_KEY")"
  m2="$(printf 'the message' | esc__hmac_openssl "$ESCALATION_KEY")"
  if [ -n "$m1" ] && [ -n "$m2" ]; then
    [ "$m1" = "$m2" ] || { echo "FAIL hmac python/openssl disagree: $m1 vs $m2"; fail=1; }
  else
    echo "WARN hmac: only one backend available (py=${#m1} ssl=${#m2})"
  fi
  [ "${#m1}" -eq 64 ] || [ "${#m2}" -eq 64 ] || { echo "FAIL hmac produced no mac"; fail=1; }
  # a different message must produce a different mac (a check that can fail)
  local m3; m3="$(printf 'the messagf' | esc__mac "$ESCALATION_KEY")"
  [ "$m3" != "$m1" ] || { echo "FAIL hmac not message-dependent"; fail=1; }

  # --- refusal record -------------------------------------------------------
  local id id2
  id="$(esc_record_refusal delete-scope Bash 'rm -rf docs/old')" || { echo "FAIL record"; fail=1; }
  case "$id" in esc-*) : ;; *) echo "FAIL id shape: $id"; fail=1 ;; esac
  id2="$(esc_record_refusal delete-scope Bash 'rm -rf docs/old')"
  [ "$id" = "$id2" ] || { echo "FAIL id not content-derived/idempotent"; fail=1; }
  id2="$(esc_record_refusal delete-scope Bash 'rm -rf docs/old ')"
  [ "$id" != "$id2" ] || { echo "FAIL one trailing space produced the same id"; fail=1; }
  [ "$(cat "$ESCALATIONS_DIR/$id.payload")" = "rm -rf docs/old" ] || { echo "FAIL payload bytes"; fail=1; }
  [ "$(esc_json_get "$ESCALATIONS_DIR/$id.json" rule)" = "delete-scope" ] || { echo "FAIL json reader"; fail=1; }
  # free text must never enter the json
  if grep -q ' ' "$ESCALATIONS_DIR/$id.json" | grep -q 'why'; then echo "FAIL prose in json"; fail=1; fi
  _t "json writer rejects free text" 1 esc__json_write "$ESCALATIONS_DIR/bad.json" note 'hello world'

  # --- record integrity: a tampered record must not survive re-derivation ---
  _t "clean record re-derives" 0 esc_record_integrity "$id"
  cp "$ESCALATIONS_DIR/$id.payload" "$ESCALATIONS_DIR/$id.payload.bak"
  printf 'rm -rf /' > "$ESCALATIONS_DIR/$id.payload"
  _t "swapped payload bytes are caught" 1 esc_record_integrity "$id"
  _grep "integrity names the payload mismatch" 'payload bytes do not match' esc_record_integrity "$id"
  mv -f "$ESCALATIONS_DIR/$id.payload.bak" "$ESCALATIONS_DIR/$id.payload"
  _t "restored record re-derives again" 0 esc_record_integrity "$id"
  # rewriting the RULE in the record must break the id derivation too
  sed -i.bak 's/"rule": "delete-scope"/"rule": "compound-git-form"/' "$ESCALATIONS_DIR/$id.json" 2>/dev/null
  _t "swapped rule is caught" 1 esc_record_integrity "$id"
  mv -f "$ESCALATIONS_DIR/$id.json.bak" "$ESCALATIONS_DIR/$id.json" 2>/dev/null
  _t "record intact after restore" 0 esc_record_integrity "$id"

  # --- approval round trip --------------------------------------------------
  local tsha rtok exp mac
  tsha="$(esc_json_get "$ESCALATIONS_DIR/$id.json" target_sha)"
  rtok="$(esc_run_token)"
  exp=$(( $(esc__now) + 1800 ))
  mac="$(esc__sign "$id" delete-scope Bash "$tsha" "$rtok" "$exp")" || { echo "FAIL sign"; fail=1; }
  esc__json_write "$ESCALATIONS_DIR/$id.approval" \
    version esc/1 kind approval id "$id" rule delete-scope tool Bash \
    target_sha "$tsha" run_token "$rtok" expiry "$exp" signed_at "$(esc__now)" mac "$mac" \
    || { echo "FAIL write approval"; fail=1; }

  _t "peek valid approval" 0 esc_peek_approval delete-scope Bash "$tsha" "$id"
  _t "peek does not consume" 0 esc_peek_approval delete-scope Bash "$tsha" "$id"
  _t "wrong tool rejected" 1 esc_peek_approval delete-scope Write "$tsha" "$id"
  _t "wrong rule rejected" 1 esc_peek_approval compound-git-form Bash "$tsha" "$id"
  _t "wrong bytes rejected" 1 esc_peek_approval delete-scope Bash "deadbeef" "$id"
  _t "check consumes" 0 esc_check_approval delete-scope Bash "$tsha" "$id"
  _t "single use enforced" 1 esc_check_approval delete-scope Bash "$tsha" "$id"
  [ -f "$ESCALATIONS_DIR/$id.approval.consumed" ] || { echo "FAIL consumed file"; fail=1; }
  grep -q '"event":"consumed"' "$ESCALATION_LEDGER" || { echo "FAIL ledger consumed line"; fail=1; }

  # ledger alone must also stop a replay (the rename is not the only record)
  mv -f "$ESCALATIONS_DIR/$id.approval.consumed" "$ESCALATIONS_DIR/$id.approval"
  _t "ledger blocks replay after file restored" 1 esc_check_approval delete-scope Bash "$tsha" "$id"
  rm -f "$ESCALATIONS_DIR/$id.approval"

  # --- guard.sh's calling convention: NO id in scope ------------------------
  # guard.sh checks for an approval BEFORE it records anything, so it can only
  # pass (rule, tool, sha256(command bytes)). If this stops working, every
  # approval verifies in testing and none is ever found in production.
  local gid gsha gmac gexp
  gsha="$(esc__sha256_str 'git add -A && git commit -m x')"
  gid="$(esc_record_refusal compound-git-form Bash 'git add -A && git commit -m x')"
  [ "$(esc_json_get "$ESCALATIONS_DIR/$gid.json" target_sha)" = "$gsha" ] \
    || { echo "FAIL Bash target_sha is not sha256 of the command bytes"; fail=1; }
  gexp=$(( $(esc__now) + 1800 ))
  gmac="$(esc__sign "$gid" compound-git-form Bash "$gsha" "$rtok" "$gexp")"
  esc__json_write "$ESCALATIONS_DIR/$gid.approval" \
    version esc/1 kind approval id "$gid" rule compound-git-form tool Bash \
    target_sha "$gsha" run_token "$rtok" expiry "$gexp" signed_at "$(esc__now)" mac "$gmac"
  ( unset ESC_LAST_ID ESC_APPROVAL_ID
    esc_check_approval compound-git-form Bash "$gsha" ) >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL approval not found without an id (guard.sh's path)"; fail=1; }

  # --- the scope-guard wiring: caller-supplied target sha -------------------
  # Without the 4th argument this records sha256(path) while the guard looks
  # for sha256(content): a signed approval that can never match. With it, the
  # record binds what the guard will actually ask for.
  local sid ssha scontent
  scontent='print("hello")
'
  ssha="$(printf '%s' "$scontent" | esc__sha256_stdin)"
  sid="$(esc_record_refusal claude-dir-write Write '.claude/hooks/notes.md' "$ssha")"
  [ "$(esc_json_get "$ESCALATIONS_DIR/$sid.json" target_sha)" = "$ssha" ] \
    || { echo "FAIL caller-supplied target_sha was not honoured"; fail=1; }
  [ "$(esc_json_get "$ESCALATIONS_DIR/$sid.json" target_kind)" = "provided" ] \
    || { echo "FAIL provided target_kind not recorded"; fail=1; }
  local smac sexp
  sexp=$(( $(esc__now) + 1800 ))
  smac="$(esc__sign "$sid" claude-dir-write Write "$ssha" "$rtok" "$sexp")"
  esc__json_write "$ESCALATIONS_DIR/$sid.approval" \
    version esc/1 kind approval id "$sid" rule claude-dir-write tool Write \
    target_sha "$ssha" run_token "$rtok" expiry "$sexp" signed_at "$(esc__now)" mac "$smac"
  ( unset ESC_LAST_ID ESC_APPROVAL_ID
    esc_check_approval claude-dir-write Write "$ssha" ) >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "FAIL scope-guard wiring: approval not found by content sha"; fail=1; }
  # and a write with no derivable target is marked underivable, not signable
  local uid2
  uid2="$(esc_record_refusal claude-dir-write Write '.claude/hooks/other.md')"
  [ "$(esc_json_get "$ESCALATIONS_DIR/$uid2.json" target_kind)" = "underivable" ] \
    || { echo "FAIL underivable write not marked"; fail=1; }

  # --- forgery, TTL, run binding -------------------------------------------
  esc__json_write "$ESCALATIONS_DIR/$id.approval" \
    version esc/1 kind approval id "$id" rule delete-scope tool Bash \
    target_sha "$tsha" run_token "$rtok" expiry "$exp" signed_at "$(esc__now)" \
    mac "0000000000000000000000000000000000000000000000000000000000000000"
  _t "forged mac rejected" 1 esc_check_approval delete-scope Bash "$tsha" "$id"

  local pexp; pexp=$(( $(esc__now) - 10 ))
  mac="$(esc__sign "$id" delete-scope Bash "$tsha" "$rtok" "$pexp")"
  esc__json_write "$ESCALATIONS_DIR/$id.approval" \
    version esc/1 kind approval id "$id" rule delete-scope tool Bash \
    target_sha "$tsha" run_token "$rtok" expiry "$pexp" signed_at "$(esc__now)" mac "$mac"
  _t "expired approval rejected" 1 esc_check_approval delete-scope Bash "$tsha" "$id"

  # Re-sign for the run-binding test. esc__sign_fresh, not esc__sign: signing
  # the same call twice in the same second yields a byte-identical MAC, which
  # the single-use ledger would (correctly) treat as a replay. This is also the
  # regression test for that -- a plain esc__sign here fails.
  local fresh
  fresh="$(esc__sign_fresh "$id" delete-scope Bash "$tsha" "$rtok" "$exp")" \
    || { echo "FAIL sign_fresh"; fail=1; }
  exp="${fresh%% *}"; mac="${fresh##* }"
  esc__json_write "$ESCALATIONS_DIR/$id.approval" \
    version esc/1 kind approval id "$id" rule delete-scope tool Bash \
    target_sha "$tsha" run_token "$rtok" expiry "$exp" signed_at "$(esc__now)" mac "$mac"
  printf 'M2\n' > "$RUN_ACTIVE"          # simulate gate closure + new run
  _t "run-bound approval dies with the run" 1 esc_check_approval delete-scope Bash "$tsha" "$id"
  printf 'M1\n' > "$RUN_ACTIVE"
  _t "same run again accepts" 0 esc_check_approval delete-scope Bash "$tsha" "$id"

  # never-escalatable is not honoured even with a valid signature
  local nid nsha nmac
  nid="$(esc_record_refusal force-push Bash 'git push --force origin main')"
  nsha="$(esc_json_get "$ESCALATIONS_DIR/$nid.json" target_sha)"
  nmac="$(esc__sign "$nid" force-push Bash "$nsha" "$rtok" "$exp")"
  esc__json_write "$ESCALATIONS_DIR/$nid.approval" \
    version esc/1 kind approval id "$nid" rule force-push tool Bash \
    target_sha "$nsha" run_token "$rtok" expiry "$exp" signed_at "$(esc__now)" mac "$nmac"
  _t "signed never-escalatable still refused" 1 esc_check_approval force-push Bash "$nsha" "$nid"

  # --- disclosures ----------------------------------------------------------
  local ftext dsha dmac
  ftext='check 7: coverage 81.2% < 85%
  src/thing.py missed lines 10-14'
  dsha="$(printf '%s' "$ftext" | esc__fail_sha cov-gate)"
  dmac="$(esc__sign "disclose-cov-gate" disclosure cov-gate "$dsha" "$rtok" 0)"
  printf '%s' "$ftext" > "$ESCALATIONS_DIR/disclosure-cov-gate-${dsha:0:8}.failure"
  esc__json_write "$ESCALATIONS_DIR/disclosure-cov-gate-${dsha:0:8}.json" \
    version esc/1 kind disclosure check cov-gate fail_sha "$dsha" run_token "$rtok" \
    expiry 0 signed_at "$(esc__now)" mac "$dmac"
  _t "disclosure verifies" 0 esc_disclose_verify cov-gate "$ftext"
  _t "different failure text is undisclosed" 1 esc_disclose_verify cov-gate 'check 7: coverage 79.0% < 85%'
  _t "different check id is undisclosed" 1 esc_disclose_verify other-gate "$ftext"
  _grep "list-disclosures prints the failure in full" 'coverage 81.2%' esc_list_disclosures
  _grep "list-disclosures says DISCLOSED is not PASS" 'DISCLOSED is not PASS' esc_list_disclosures
  _grep "list-disclosures prints the second line too" 'missed lines 10-14' esc_list_disclosures
  # trailing-whitespace-only difference must still match (terminal noise only)
  _t "normalization tolerates trailing spaces" 0 esc_disclose_verify cov-gate "$(printf 'check 7: coverage 81.2%% < 85%%   \n  src/thing.py missed lines 10-14  ')"

  # --- postcondition --------------------------------------------------------
  _t "postcondition not pending initially" 1 esc_postcondition_pending
  esc_postcondition_arm "selftest" >/dev/null 2>&1
  _t "postcondition pending after arm" 0 esc_postcondition_pending
  _t "remedy is reachable" 0 esc_postcondition_is_remedy "bash .claude/hooks/escalate.sh postcondition-clear"
  _t "unrelated command is not the remedy" 1 esc_postcondition_is_remedy "git commit -m x"
  _grep "remedy command names the clear verb" 'escalate.sh postcondition-clear' esc_postcondition_remedy_cmd
  # The remedy must never be approve.sh: the agent may never run that, so a
  # marker whose remedy is approve.sh is a marker that can never be cleared.
  if esc_postcondition_remedy_cmd > "$ESCALATIONS_DIR/.remedy" 2>&1; then
    grep -q 'approve.sh' "$ESCALATIONS_DIR/.remedy" && { echo "FAIL remedy points at approve.sh"; fail=1; }
    rm -f "$ESCALATIONS_DIR/.remedy"
  fi
  rm -f "$(esc__pc_marker)"

  # --- expire all -----------------------------------------------------------
  esc__json_write "$ESCALATIONS_DIR/$id.approval" \
    version esc/1 kind approval id "$id" rule delete-scope tool Bash \
    target_sha "$tsha" run_token "$rtok" expiry "$exp" signed_at "$(esc__now)" mac "$mac"
  esc_expire_all >/dev/null 2>&1
  [ -f "$ESCALATIONS_DIR/$id.approval" ] && { echo "FAIL expire_all left an approval"; fail=1; }
  [ "$(esc_disclosure_count)" = "0" ] || { echo "FAIL expire_all left a disclosure"; fail=1; }
  [ -r "$ESCALATION_LEDGER" ] || { echo "FAIL expire_all removed the ledger"; fail=1; }

  # --- helpers --------------------------------------------------------------
  _t "approve.sh invocation detected (bare)" 0 esc_cmd_invokes_approve "approve.sh esc-1"
  _t "approve.sh invocation detected (wrapped)" 0 esc_cmd_invokes_approve "env X=1 bash ./.claude/hooks/approve.sh esc-1"
  _t "unrelated command not flagged" 1 esc_cmd_invokes_approve "git status"
  _t "secrets path detected" 0 esc_path_is_key_or_secrets "secrets/escalation.key"
  _t "secrets subdir detected" 0 esc_path_is_key_or_secrets "./secrets/nested/x"
  _t "unrelated path not flagged" 1 esc_path_is_key_or_secrets "src/secretsauce.py"
  _t "rule id validator rejects junk" 1 esc_rule_id_valid "Force_Push"
  _t "rule id validator accepts kebab" 0 esc_rule_id_valid "force-push"

  # --- EVERY RULE ID THE REAL GUARDS PUBLISH MUST CLASSIFY ------------------
  # This is the cross-check that makes "an unclassified rule surfaces loudly"
  # true rather than aspirational. guard.sh (and any other guard that grows the
  # verb) publishes its vocabulary with --list-rules; if one of its ids is not
  # in this file's partition, the control-layer selftest fails HERE, at build
  # time, instead of an agent discovering at 2am that a confirmable refusal was
  # silently being treated as a wall.
  # It found a real one on first run: guard.sh emits `compound-git-form` and
  # this file had called it `compound-git-command`.
  local g gids unclassified
  for g in guard.sh scope-guard.sh stop-gate.sh subagent-gate.sh red-gate.sh; do
    [ -r "$ESC_LIB_DIR/$g" ] || continue
    grep -q -- '--list-rules' "$ESC_LIB_DIR/$g" 2>/dev/null || continue
    gids="$(bash "$ESC_LIB_DIR/$g" --list-rules 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    [ -n "$gids" ] || continue
    # shellcheck disable=SC2086
    unclassified="$(esc_assert_classified $gids 2>/dev/null)"
    if [ -n "$unclassified" ]; then
      echo "FAIL $g publishes rule ids this library does not classify:"
      printf '  %s\n' "$unclassified"
      fail=1
    fi
  done
  rm -f "$ESCALATIONS_DIR/unclassified-rules.log" 2>/dev/null

  # --- unclassified log is the failure signal ------------------------------
  if [ -s "$ESCALATIONS_DIR/unclassified-rules.log" ]; then
    echo "FAIL unclassified rules were logged during a clean run:"
    cat "$ESCALATIONS_DIR/unclassified-rules.log"
    fail=1
  fi

  rm -rf "$root" 2>/dev/null
  unset -f _t _grep
  if [ "$fail" -eq 0 ]; then echo "escalation-lib.sh selftest PASS"; else echo "escalation-lib.sh selftest FAIL"; fi
  return "$fail"
}

esc__main() {
  case "${1:---help}" in
    classify)          esc_classify "${2:-}"; printf '\n' ;;
    is-never)          esc_is_never_escalatable "${2:-}"; exit $? ;;
    vocabulary)        esc_rule_vocabulary ;;
    run-token)         esc_run_token; printf '\n' ;;
    record)            esc_record_refusal "${2:-}" "${3:-}" "${4:-}"; local r=$?; printf '\n'; exit "$r" ;;
    notice)            esc_refusal_notice "${2:-}" "${3:-}" ;;
    integrity)         esc_record_integrity "${2:-}"; exit $? ;;
    peek)              esc_peek_approval "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $? ;;
    check)             esc_check_approval "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $? ;;
    target-sha)        esc_target_sha "${2:-}" "${3:-}"; local r=$?; printf '\n'; exit "$r" ;;
    disclose-verify)   esc_disclose_verify "${2:-}" "${3:-}"; exit $? ;;
    list-disclosures)  esc_list_disclosures ;;
    disclosure-count)  esc_disclosure_count; printf '\n' ;;
    record-failure)    esc_record_failure "${2:-}" "${3:-}"; exit $? ;;
    postcondition-status)
                       if esc_postcondition_pending; then
                         printf 'PENDING\n'; cat "$(esc__pc_marker)" 2>/dev/null; exit 0
                       else printf 'CLEAR\n'; exit 1; fi ;;
    postcondition-clear) esc_postcondition_clear; exit $? ;;
    postcondition-baseline) esc_postcondition_baseline_write; exit $? ;;
    expire-all)        esc_expire_all; exit $? ;;
    --selftest)        esc__selftest; exit $? ;;
    --help|-h)         esc__usage ;;
    *)                 esc__usage; exit 2 ;;
  esac
}

# Executed directly (not sourced)?
case "${0##*/}" in
  escalation-lib.sh)
    set -uo pipefail
    esc__main "$@"
    ;;
esac
