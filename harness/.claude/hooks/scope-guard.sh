#!/usr/bin/env bash
# scope-guard.sh - PreToolUse/Edit|Write|NotebookEdit. The file-write half of the control layer.
# HUMANS: do not edit. This file is control-set / Tier 2b and never escalatable.
# ------------------------------------------------------------------------------------------------
# Contract:
#   in   : hook payload JSON on stdin; the path is tool_input.file_path (Edit/Write) or
#          tool_input.notebook_path (NotebookEdit)
#   out  : exit 0 = allow (silent) | exit 2 = BLOCK, reason on stderr (CONTRACT SS3)
#   also : one line per decision appended to $CMD_LOG
#
# Four questions, in this order, because a later answer must never be able to admit a path an
# earlier one denied:
#   1. Is this path Tier 2b?          governing corpus, control set, secrets, escalation store,
#                                     forbidden artifacts. Never escalatable. Nothing lifts these.
#   2. Is it under .claude/ at all?    Refused by default, liftable for ONE byte-exact write.
#   3. Is it inside the dispatch's partition glob?  PIPELINE_PARTITION_GLOB is a mechanical write
#                                     allow-list, not advice. Read from DISK first (the env var
#                                     does not reliably reach hook environments), env as fallback.
#   4. Is it in the run's manifest?    Only while a run is active AND a plan exists - with no run
#                                     there is no definition of done to enforce, and a manifest
#                                     from a CLOSED milestone must never gate an unrelated session.
#
# On attribution: this hook does not need it. A PreToolUse write is unambiguously the work of the
# agent making the call, which is exactly the certainty the post-hoc gates lack. Those gates use
# rt_attributable, and below `exact` they may only REPORT - never order a revert.
#
# Standalone: `scope-guard.sh --list-rules`, `scope-guard.sh --selftest`.
# ------------------------------------------------------------------------------------------------
set -uo pipefail

_s_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=hooklib.sh disable=SC1090,SC1091
. "$_s_dir/hooklib.sh"

rt_rule_ids() {
  cat <<'EOF'
banned-read-files
claude-dir-write
control-set-write
dispatch-store-write
escalation-store-write
forbidden-artifacts
governing-corpus-write
manifest-scope-violation
partition-glob-violation
secrets-access
unparsable-payload
EOF
}

case "${1:-}" in
  --list-rules) rt_rule_ids; exit 0 ;;
esac

# escalation binding - absent library means every rule is treated as never-escalatable (fail closed)
S_ESC=0
if [ -f "$HOOKS_DIR/escalation-lib.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOKS_DIR/escalation-lib.sh" 2>/dev/null && S_ESC=1
fi
if [ "$S_ESC" = "1" ]; then
  declare -F esc_is_never_escalatable >/dev/null 2>&1 || S_ESC=0
  declare -F esc_check_approval       >/dev/null 2>&1 || S_ESC=0
  declare -F esc_record_refusal       >/dev/null 2>&1 || S_ESC=0
fi

S_TOOL=""
S_PATH=""
S_REL=""
S_CONTENT=""
S_HAS_CONTENT=0

# s_target_sha - what an approval for THIS write would be bound to.
# For a Write we can name the resulting file exactly: sha256 of the content that would land.
# For an Edit we cannot - the result depends on the current file and on old_string being unique -
# so no approval can exist and we say so instead of pretending one might.
s_target_sha() {
  if [ "$S_HAS_CONTENT" = "1" ]; then rt_sha256_str "$S_CONTENT" 2>/dev/null; fi
}

s_refuse() {
  local rule="$1" head="$2"; shift 2
  local sha="" esc_id never=1 d msg
  sha=$(s_target_sha) || sha=""

  if [ "$S_ESC" = "1" ] && ! esc_is_never_escalatable "$rule" 2>/dev/null; then
    never=0
    if [ -n "$sha" ] && esc_check_approval "$rule" "$S_TOOL" "$sha" 2>/dev/null; then
      rt_log_cmd "$S_TOOL" "ALLOW-APPROVED" "$rule" "$sha" "$S_REL"
      rt_event scope_allow_approved "rule=$rule" "path=$S_REL"
      printf 'ratchet: a human approval for this exact resulting file was found and consumed (rule=%s).\n' "$rule" >&2
      exit 0
    fi
  fi

  msg="RATCHET BLOCK [rule=$rule]"$'\n'"$head"
  for d in "$@"; do msg="$msg"$'\n'"  $d"; done

  if [ "$never" = "0" ]; then
    esc_id=$(esc_record_refusal "$rule" "$S_TOOL" "$S_REL" "$sha" 2>/dev/null | tr -d '\r\n')
    [ -n "$esc_id" ] || esc_id="$rule"
    msg="$msg"$'\n\n'"This refusal is ESCALATABLE (id=$esc_id)"
    msg="$msg"$'\n'"  $HOOKS_DIR/escalate.sh request $esc_id \"why this exact write is needed\""
    msg="$msg"$'\n'"  Then raise a Decision Card. A human runs approve.sh $esc_id in their own"
    msg="$msg"$'\n'"  terminal; re-issue the IDENTICAL write and it is permitted exactly once."
    if [ "$S_HAS_CONTENT" != "1" ]; then
      msg="$msg"$'\n'"  NOTE: an approval binds to the sha256 of the RESULTING FILE. This is an $S_TOOL,"
      msg="$msg"$'\n'"  whose result is not derivable in advance - re-issue it as a Write carrying the"
      msg="$msg"$'\n'"  complete file content, or it cannot be approved at all."
    fi
  else
    msg="$msg"$'\n\n'"This refusal is NOT escalatable. No approval, card or domain pack lifts it."
    if [ "$S_ESC" = "0" ]; then
      msg="$msg"$'\n'"  (escalation-lib.sh unavailable - every rule is treated as never-escalatable.)"
    fi
  fi

  rt_log_cmd "$S_TOOL" "BLOCK" "$rule" "$sha" "$S_REL"
  rt_event scope_block "rule=$rule" "path=$S_REL"
  rt_block "$msg"
}

# ------------------------------------------------------------------------------------- payload read
if [ "${1:-}" != "--selftest" ]; then
  rt_payload >/dev/null            # prime the cache in THIS shell (see rt_payload's header)
  S_PAYLOAD="${RT_PAYLOAD:-}"
  if [ -z "$S_PAYLOAD" ]; then
    if [ -t 0 ]; then
      printf 'ratchet: scope-guard.sh got no hook payload on stdin. Try --selftest or --list-rules.\n' >&2
      exit 0
    fi
    s_refuse unparsable-payload "The hook payload was empty; a write cannot be shown to be in scope."
  fi

  S_TOOL=$(rt_json_field tool_name) || S_TOOL=""
  case "$S_TOOL" in
    Edit|Write|NotebookEdit|MultiEdit) ;;
    "") s_refuse unparsable-payload "Could not read tool_name from the hook payload." ;;
    *)  exit 0 ;;
  esac

  S_PATH=$(rt_json_field tool_input.file_path) || S_PATH=""
  [ -n "$S_PATH" ] || S_PATH=$(rt_json_field tool_input.notebook_path) || S_PATH=""
  if [ -z "$S_PATH" ]; then
    s_refuse unparsable-payload "Tool is $S_TOOL but no file path could be read from the payload."
  fi
  S_CONTENT=$(rt_json_field tool_input.content) && S_HAS_CONTENT=1 || S_HAS_CONTENT=0
fi

rt_touch_seen
rt_repo_rel_var "$S_PATH"; S_REL="$RT_REL"

# =================================================================================================
# 1. Tier 2b - never escalatable, no exceptions, checked before anything else
# =================================================================================================
# The ONE sanctioned agent write to the human's contracts. TEMPLATE.md SS1 and the
# SPEC.md/MILESTONES.md placeholders themselves name a single pre-run drafting
# pass in which an agent fills these two files, then hands them over. That pass
# was impossible: this guard refused the write never-escalatably, so the doctrine
# described a path no code allowed and a fresh project could not be started by an
# agent. The exemption is gated on the file's OWN on-disk state - an unwritten
# placeholder still carrying `<!-- ratchet:unwritten -->` is not yet the
# protected contract - NOT on an approval, env var, or domain pack, so it does
# not become "Tier 2b unless someone clicks yes". It is one-way: the moment the
# marker is gone the file is corpus forever, and re-inserting the marker is
# itself a governing-corpus write this guard blocks. Nothing an agent controls
# can re-open it. Scoped to exactly the two contract files by name; the doctrine
# files (.claude/doctrine/*) never qualify.
UNWRITTEN_MARKER='<!-- ratchet:unwritten -->'
s_is_unwritten_bootstrap() {
  local rel="$1" f
  case "$rel" in
    "${CONTEXT_DIR:-.context}/SPEC.md"|"${CONTEXT_DIR:-.context}/MILESTONES.md") ;;
    *) return 1 ;;
  esac
  f="${REPO_ROOT:-.}/$rel"
  [ -f "$f" ] || return 1
  grep -qF -- "$UNWRITTEN_MARKER" "$f" 2>/dev/null || return 1
  return 0
}

s_check_tier2b() {
  S_BOOTSTRAP=0
  s_is_unwritten_bootstrap "$S_REL" && S_BOOTSTRAP=1

  if rt_is_secret_path "$S_REL"; then
    s_refuse secrets-access \
      "This path is a secret: $S_REL" \
      "Credentials reach the process through the environment, never through a file in the tree." \
      "If this is a committed template, add it to SECRET_EXEMPTIONS in domain.config.sh - in the" \
      "open, once, rather than per write."
  fi

  if [ "$S_BOOTSTRAP" != "1" ] && rt_path_matches_list "$S_REL" "${GOVERNING_CORPUS:-}"; then
    s_refuse governing-corpus-write \
      "This path is in the governing corpus: $S_REL" \
      "The governing corpus is Tier 2b: read it freely, never write it. Propose the change through" \
      "the decision log and the retrospective, which is the path a human can actually review."
  fi

  if rt_is_control_set "$S_REL"; then
    s_refuse control-set-write \
      "This path is a control-layer file: $S_REL" \
      "The files that decide what an approval MEANS cannot be changed by an approval. Without that" \
      "line, Tier 2b becomes 'Tier 2b unless someone clicks yes'."
  fi

  case "$S_REL/" in
    "$ESCALATIONS_DIR"/*|"$SECRETS_DIR"/*)
      s_refuse escalation-store-write \
        "This path is inside the escalation store: $S_REL" \
        "An agent that can write the ledger can approve itself. escalate.sh and approve.sh are the" \
        "only writers, and approve.sh is human-only." ;;
  esac

  # The dispatch store must be checked HERE, in tier2b, because s_check_partition returns
  # early for everything under $PIPELINE_DIR/ and SCOPE_EXEMPT_PREFIXES exempts it from the
  # manifest. A rule placed any later never fires.
  case "$S_REL/" in
    "$DISPATCH_DIR"/*)
      s_refuse dispatch-store-write \
        "This path is inside the dispatch attribution store: $S_REL" \
        "This is the file your own writes are checked against, and the baseline the SubagentStop" \
        "gates attribute work with. An agent that can widen its own glob has no glob." ;;
  esac

  if rt_path_matches_list "$S_REL" "${FORBIDDEN_ARTIFACTS:-}"; then
    s_refuse forbidden-artifacts \
      "This path is a domain-forbidden artifact: $S_REL" \
      "FORBIDDEN_ARTIFACTS names files whose mere existence changes what the system may do."
  fi

  if rt_path_matches_list "$S_REL" "${BANNED_READ_FILES:-}"; then
    s_refuse banned-read-files \
      "This path is a banned context-poisoning file: $S_REL" \
      "It is banned because loading it costs a context window of stale requirements. Writing it" \
      "keeps it alive for the next agent that stumbles into it."
  fi
}

# =================================================================================================
# 2. the rest of .claude/ - refused by default, liftable for ONE byte-exact write
# =================================================================================================
s_check_claude_dir() {
  case "$S_REL/" in
    "$CLAUDE_DIR"/*)
      s_refuse claude-dir-write \
        "This path is inside the control layer: $S_REL" \
        "Agent definitions and non-control hooks are changeable, but never silently: an approved" \
        "write must also leave the control layer green, because a refusal from a broken guard is" \
        "the one refusal nobody can trust." ;;
  esac
}

# =================================================================================================
# 3. partition glob - the dispatch's mechanical write allow-list
# =================================================================================================
# Read from disk first: .pipeline/dispatch/<id>.glob, where <id> comes from
# .pipeline/dispatch/current. PIPELINE_PARTITION_GLOB is a FALLBACK, because the env var does not
# reliably reach hook environments from the Agent tool (measured).
# With no glob on disk and none in the environment this check is inert - that is the weak
# attribution mode, and weak mode may not block a write it cannot attribute.
s_check_partition() {
  local globs
  globs=$(rt_dispatch_glob) || return 0
  [ -n "$globs" ] || return 0
  case "$S_REL/" in
    "$PIPELINE_DIR"/*|"$DEV_DIR"/*) return 0 ;;   # scratch and the learning loop are never partitioned
  esac
  if rt_glob_match "$S_REL" "$globs"; then return 0; fi
  s_refuse partition-glob-violation \
    "This path is outside the partition glob for dispatch $(rt_dispatch_id): $S_REL" \
    "Allowed globs:" \
    "$(printf '%s' "$globs" | tr '\n' ' ')" \
    "A developer dispatched with the test-writer's glob is blocked from every file it exists to" \
    "write, and a test-writer dispatched with the developer's is un-gated on exactly the boundary" \
    "TDD depends on. If the glob is wrong, the dispatch is wrong - fix it there, not here."
}

# =================================================================================================
# 4. manifest membership - only while a run is active AND a plan exists
# =================================================================================================
# Inert with no run: outside a run there is no definition of done to enforce, and a manifest from a
# closed milestone must never gate an unrelated session.
# Inert with no plan file: at Stage 0-2 the plan does not exist yet, and the architect must be able
# to write the very file that will do the gating.
s_check_manifest() {
  rt_run_active || return 0
  [ -f "${PLAN_FILES:-}" ] || return 0
  local pfx
  while IFS= read -r pfx; do
    pfx=$(rt_trim "$pfx"); [ -n "$pfx" ] || continue
    case "$S_REL/" in "$pfx"*) return 0 ;; esac
  done <<< "${SCOPE_EXEMPT_PREFIXES:-}"
  rt_in_manifest "$S_REL" && return 0
  s_refuse manifest-scope-violation \
    "This path is not in the manifest for milestone $(rt_run_milestone): $S_REL" \
    "Scope growth inside a milestone is a normal, decidable event - it is not an escalation." \
    "Append one line to $AMENDMENTS in the form:" \
    "    $S_REL DEC-nnn <one impact line: what else this widened scope now touches>" \
    "with the matching decision entry in the same commit. That exact form is what the Stop gate" \
    "and check_done.py both parse, from one shared parser."
}

# =================================================================================================
# selftest
# =================================================================================================
if [ "${1:-}" = "--selftest" ]; then
  _self="$_s_dir/${0##*/}"
  [ -f "$_self" ] || _self="${BASH_SOURCE[0]:-$0}"
  _fails=0
  _run() {  # <expected-rule|ALLOW> <label> <tool> <path> [content]
    local exp="$1" label="$2" tool="$3" path="$4" content="${5-}" rc out got payload
    if [ -n "$content" ]; then
      payload=$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s","content":"%s"}}' \
                "$tool" "$(rt_json_escape "$path")" "$(rt_json_escape "$content")")
    else
      payload=$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
                "$tool" "$(rt_json_escape "$path")")
    fi
    out=$(printf '%s' "$payload" | bash "$_self" 2>&1); rc=$?
    got=$(printf '%s' "$out" | sed -n 's/.*RATCHET BLOCK \[rule=\([a-z0-9-]*\)\].*/\1/p' | head -n 1)
    [ "$rc" = "0" ] && got="ALLOW"
    if [ "$got" = "$exp" ]; then printf '  ok   %-34s %s\n' "$label" "$got"; return 0; fi
    printf '  FAIL %-34s expected %s got %s (exit %s) %s\n' "$label" "$exp" "${got:-?}" "$rc" \
           "$(printf '%s' "$out" | head -n 1)"
    _fails=$((_fails+1)); return 1
  }
  printf 'scope-guard.sh selftest\n'
  _run ALLOW                  "ordinary source write"   Write "src/thing.py" "x = 1"
  _run ALLOW                  "scratch write"           Write ".pipeline/notes.md" "hi"
  # Corpus cases use a doctrine file: it is always corpus and never eligible for
  # the bootstrap exemption, so this assertion does not depend on whether the
  # project's own .context/SPEC.md has been written yet.
  _run governing-corpus-write "corpus edit"             Edit  ".claude/doctrine/PIPELINE.md"
  _run governing-corpus-write "corpus via ../"          Edit  ".pipeline/../.claude/doctrine/PIPELINE.md"
  _run control-set-write      "control set write"       Write ".claude/hooks/guard.sh" "x"
  _run claude-dir-write       "agent definition write"  Write ".claude/agents/scout.md" "x"
  _run secrets-access         "dotenv write"            Write ".env" "TOKEN=1"
  _run ALLOW                  "dotenv example allowed"  Write ".env.example" "TOKEN="
  _run secrets-access         "key write"               Write "secrets/escalation.key" "x"
  _run escalation-store-write "ledger write"            Write ".pipeline/escalations/ledger.jsonl" "{}"
  _run dispatch-store-write   "partition glob widened"  Write ".pipeline/dispatch/p1.glob" "**"
  _run dispatch-store-write   "attribution baseline"    Write ".pipeline/dispatch/p1.baseline" "x"
  _run dispatch-store-write   "dispatch pointer"        Write ".pipeline/dispatch/current" "p1"
  _run unparsable-payload     "no path in payload"      Write "" ""

  # bootstrap exemption: the ONE sanctioned agent write to an UNWRITTEN contract,
  # and the lock the instant the marker is gone. Driven against temp files made
  # corpus and treated as the two contracts via CONTEXT_DIR/GOVERNING_CORPUS.
  _bd=".pipeline/bootstrap-selftest"; mkdir -p "$_bd"
  printf '%s\nNOT YET WRITTEN\n' "$UNWRITTEN_MARKER" > "$_bd/SPEC.md"
  printf 'REAL SPEC, marker removed, owned by the human now\n' > "$_bd/MILESTONES.md"
  ( export CONTEXT_DIR="$_bd" \
           GOVERNING_CORPUS="$_bd/SPEC.md"$'\n'"$_bd/MILESTONES.md"
    _run ALLOW                  "unwritten contract (bootstrap)" Write "$_bd/SPEC.md" "real content"
    _run governing-corpus-write "written contract (locked)"     Write "$_bd/MILESTONES.md" "more" ) \
    || _fails=$((_fails+1))
  rm -f "$_bd/SPEC.md" "$_bd/MILESTONES.md" 2>/dev/null; rmdir "$_bd" 2>/dev/null || true

  # domain lists
  ( export FORBIDDEN_ARTIFACTS="LIVE_CONFIRMED"; _run forbidden-artifacts "domain artifact" Write "LIVE_CONFIRMED" "1" ) \
    || _fails=$((_fails+1))
  ( export BANNED_READ_FILES="docs/old-dump.md"; _run banned-read-files "domain banned file" Write "docs/old-dump.md" "1" ) \
    || _fails=$((_fails+1))

  # partition glob, from disk
  _tmpd="${PIPELINE_DIR:-.pipeline}/dispatch"
  mkdir -p "$_tmpd" 2>/dev/null
  printf 'selftest-dispatch\n' > "$_tmpd/current"
  printf 'src/core/*\n' > "$_tmpd/selftest-dispatch.glob"
  _run ALLOW                     "inside partition glob"  Write "src/core/a.py" "x"
  _run partition-glob-violation  "outside partition glob" Write "tests/test_a.py" "x"
  rm -f "$_tmpd/current" "$_tmpd/selftest-dispatch.glob"

  # manifest membership, only while a run is active
  _ra="${RUN_ACTIVE:-.pipeline/run-active}"; _pf="${PLAN_FILES:-.pipeline/plan-files.txt}"
  _had_ra=0; [ -f "$_ra" ] && _had_ra=1
  if [ "$_had_ra" = "0" ]; then
    mkdir -p "$(dirname "$_ra")" 2>/dev/null
    printf 'M-selftest\n' > "$_ra"
    printf 'src/allowed.py\n' > "$_pf"
    _run ALLOW                     "in manifest"      Write "src/allowed.py" "x"
    _run manifest-scope-violation  "outside manifest" Write "src/other.py" "x"
    rm -f "$_ra" "$_pf"
    # and inert once the run is closed
    _run ALLOW                     "manifest inert, no run" Write "src/other.py" "x"
  else
    printf '  note a run is active in this repo; manifest cases skipped\n'
  fi

  _declared=$(rt_rule_ids)
  _used=$(grep -v '^[[:space:]]*#' "$_self" | grep -oE 's_refuse [a-z][a-z0-9-]+' | awk '{print $2}' | sort -u)
  while IFS= read -r _u; do
    [ -n "$_u" ] || continue
    printf '%s\n' "$_declared" | grep -qx -- "$_u" || {
      printf '  FAIL rule id %s is emitted but not in rt_rule_ids\n' "$_u"; _fails=$((_fails+1)); }
  done <<< "$_used"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    printf '%s\n' "$_used" | grep -qx -- "$_d" || {
      printf '  FAIL rule id %s is declared but never emitted\n' "$_d"; _fails=$((_fails+1)); }
  done <<< "$_declared"
  printf '  ok   %s rule ids declared, %s emitted\n' \
    "$(printf '%s\n' "$_declared" | grep -c .)" "$(printf '%s\n' "$_used" | grep -c .)"

  [ "$_fails" -gt 0 ] && { printf 'scope-guard.sh selftest: %s FAILURE(S)\n' "$_fails" >&2; exit 1; }
  printf 'scope-guard.sh selftest: OK\n'
  exit 0
fi

# =================================================================================================
s_check_tier2b
s_check_claude_dir
s_check_partition
s_check_manifest
rt_log_cmd "$S_TOOL" "ALLOW" "-" "" "$S_REL"
exit 0
