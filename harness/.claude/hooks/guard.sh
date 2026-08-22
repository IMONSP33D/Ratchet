#!/usr/bin/env bash
# guard.sh - PreToolUse/Bash. The command-line half of the control layer.
# HUMANS: do not edit. This file is control-set / Tier 2b and never escalatable.
# ------------------------------------------------------------------------------------------------
# Contract:
#   in   : hook payload JSON on stdin ({"tool_name":"Bash","tool_input":{"command":"..."}})
#   out  : exit 0 = allow (silent) | exit 2 = BLOCK, reason on stderr (CONTRACT SS3)
#   also : one line per decision appended to $CMD_LOG (format documented at rt_log_cmd)
#
# Two things about this file are load-bearing and easy to get wrong:
#
# 1. IT DECIDES BY EFFECT, NEVER BY VERB (CONTRACT SS0.4). Write-effect detection - redirects,
#    cp/mv/ln, tee, dd, truncate, patch, sed -i, heredocs - runs BEFORE any "that's just a read
#    command" carve-out. `cat notes.md > .context/SPEC.md` starts with `cat`; it is a corpus write.
#    Reorder these blocks and you reintroduce that hole.
#
# 2. IT READS THE COMMAND TWICE, through two different views (see rt_strip_data / rt_strip_msg).
#    The structural view answers "what does the shell do"; the target view answers "what does this
#    touch". One view cannot answer both without either blocking commit messages or missing
#    redirects.
#
# Every refusal names a stable kebab-case RULE ID. The ids are the vocabulary the escalation
# classifier and the self-test share: `guard.sh --list-rules` prints all of them, so a rule that
# nobody classified is mechanically detectable.
#
# Standalone: `guard.sh --list-rules`, `guard.sh --selftest`.
# ------------------------------------------------------------------------------------------------
set -uo pipefail

_g_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=hooklib.sh disable=SC1090,SC1091
. "$_g_dir/hooklib.sh"

# ---------------------------------------------------------------------------------- rule vocabulary
# Every id this script can emit. Keep alphabetical; keep in sync with the refusals below (the
# selftest asserts every g_refuse id appears here).
rt_rule_ids() {
  cat <<'EOF'
approve-script-invocation
banned-read-files
base-branch-commit
base-branch-push
claude-dir-write
compound-git-form
control-set-write
delete-scope
escalation-store-write
forbidden-artifacts
forbidden-exec-tokens
force-push
git-config-write
git-remote-write
governing-corpus-write
inline-interpreter
no-verify-flag
push-target-unprovable
secrets-access
ship-consent-missing
ship-consent-unparsable
unparsable-command
unparsable-payload
EOF
}

case "${1:-}" in
  --list-rules) rt_rule_ids; exit 0 ;;
esac

# ------------------------------------------------------------------------------ escalation binding
# escalation-lib.sh is owned by another builder. If it is absent we FAIL CLOSED: every rule is
# treated as never-escalatable, so a missing library can only ever make the guard stricter.
G_ESC=0
if [ -f "$HOOKS_DIR/escalation-lib.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOKS_DIR/escalation-lib.sh" 2>/dev/null && G_ESC=1
fi
if [ "$G_ESC" = "1" ]; then
  declare -F esc_is_never_escalatable >/dev/null 2>&1 || G_ESC=0
  declare -F esc_check_approval       >/dev/null 2>&1 || G_ESC=0
  declare -F esc_record_refusal       >/dev/null 2>&1 || G_ESC=0
fi

CMD=""
TOOL=""

# g_refuse <rule-id> <headline> [detail...]
# Checks for a live approval first (that is the "re-issue the identical call" path), then blocks.
g_refuse() {
  local rule="$1" head="$2"; shift 2
  local sha="" esc_id never=1 d msg
  sha=$(rt_sha256_str "$CMD" 2>/dev/null) || sha=""

  if [ "$G_ESC" = "1" ] && ! esc_is_never_escalatable "$rule" 2>/dev/null; then
    never=0
    # No digest tool means no way to bind an approval to these exact bytes -> no approval exists.
    if [ -n "$sha" ] && esc_check_approval "$rule" "Bash" "$sha" 2>/dev/null; then
      rt_log_cmd "Bash" "ALLOW-APPROVED" "$rule" "$sha" "$CMD"
      rt_event guard_allow_approved "rule=$rule" "tool=Bash"
      printf 'ratchet: a human approval for these exact bytes was found and consumed (rule=%s).\n' "$rule" >&2
      exit 0
    fi
  fi

  msg="RATCHET BLOCK [rule=$rule]"$'\n'"$head"
  for d in "$@"; do msg="$msg"$'\n'"  $d"; done

  if [ "$never" = "0" ]; then
    esc_id=$(esc_record_refusal "$rule" "Bash" "$CMD" 2>/dev/null | tr -d '\r\n')
    [ -n "$esc_id" ] || esc_id="$rule"
    msg="$msg"$'\n\n'"This refusal is ESCALATABLE (id=$esc_id)"
    msg="$msg"$'\n'"  $HOOKS_DIR/escalate.sh request $esc_id \"why this exact call is needed\""
    msg="$msg"$'\n'"  Then raise a Decision Card. A human runs approve.sh $esc_id in their own"
    msg="$msg"$'\n'"  terminal; re-issue the IDENTICAL call and it is permitted exactly once."
  else
    msg="$msg"$'\n\n'"This refusal is NOT escalatable. No approval, card or domain pack lifts it."
    if [ "$G_ESC" = "0" ]; then
      msg="$msg"$'\n'"  (escalation-lib.sh unavailable - every rule is treated as never-escalatable.)"
    fi
    msg="$msg"$'\n'"  Take a different approach, or run the Hard Stop flow."
  fi

  rt_log_cmd "Bash" "BLOCK" "$rule" "$sha" "$CMD"
  rt_event guard_block "rule=$rule" "tool=Bash"
  rt_block "$msg"
}

# ------------------------------------------------------------------------------------- payload read
if [ "${1:-}" != "--selftest" ]; then
  # Prime the payload cache IN THIS SHELL. `$(rt_payload)` would read stdin inside a subshell and
  # the cache would die with it, leaving every later field read looking at a consumed stdin.
  rt_payload >/dev/null
  G_PAYLOAD="${RT_PAYLOAD:-}"
  if [ -z "$G_PAYLOAD" ]; then
    if [ -t 0 ]; then
      printf 'ratchet: guard.sh got no hook payload on stdin. Try --selftest or --list-rules.\n' >&2
      exit 0
    fi
    g_refuse unparsable-payload "The hook payload was empty; a Bash call cannot be shown to be safe."
  fi

  TOOL=$(rt_json_field tool_name) || TOOL=""
  case "$TOOL" in
    Bash) ;;
    "")   g_refuse unparsable-payload "Could not read tool_name from the hook payload." \
                   "A payload this guard cannot parse is a payload it cannot clear." ;;
    *)    exit 0 ;;   # not our matcher
  esac

  CMD=$(rt_json_field tool_input.command) || CMD=""
  if [ -z "$CMD" ]; then
    g_refuse unparsable-payload "Tool is Bash but tool_input.command could not be read."
  fi
fi

rt_touch_seen

# =================================================================================================
# views + derived facts
# =================================================================================================
g_analyse() {
  G_STRUCT=$(rt_strip_data "$CMD")
  if ! G_TARGET=$(rt_strip_msg "$CMD"); then
    g_refuse unparsable-command "The command has an unterminated quote and cannot be parsed." \
             "A command whose structure is ambiguous cannot be shown to be safe (fail closed)."
  fi
  # Tokenise the target view ONCE. Every rule below reads $G_TOK; re-tokenising per rule cost a
  # fork per rule, which on Git-Bash is most of the guard's latency.
  G_TOK=$(rt_tokenize "$G_TARGET")
  G_TOKENS=$(rt_cmd_tokens "$CMD")
  G_WRITES=$(rt_write_targets "$CMD") || G_WRITES=""
  G_TARGET_LC=$(rt_lc "$G_TARGET")
}

# first matching path from a newline list of candidate paths against a deny list
g_match_in() {   # <candidate-paths> <deny-list>  -> echoes the offending path
  local c
  [ -n "${2-}" ] || return 1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in -*) continue ;; esac
    if rt_path_matches_list "$c" "$2"; then printf '%s' "$c"; return 0; fi
  done <<< "${1-}"
  return 1
}

# non-flag arguments appearing after the first plain token whose basename is <verb>
g_args_after() {  # <verb>
  local want="$1" flag val hit=0
  while IFS=$'\t' read -r flag val; do
    [ -n "$flag" ] || continue
    if [ "$hit" = "0" ]; then
      [ "$flag" = "P" ] && [ "${val##*/}" = "$want" ] && hit=1
      continue
    fi
    case "$val" in -*|'>'*|'<'*|'|'|'&&'|'||'|';') continue ;; esac
    printf '%s\n' "$val"
  done <<< "$G_TOK"
  return 0
}

g_has_word() {   # <word> - a plain (unquoted) token equal to <word>, basename-insensitive
  local want="$1" flag val
  while IFS=$'\t' read -r flag val; do
    [ "$flag" = "P" ] || continue
    [ "${val##*/}" = "$want" ] && return 0
  done <<< "$G_TOK"
  return 1
}

g_branch() {
  [ -n "${G_BRANCH+x}" ] && { printf '%s' "$G_BRANCH"; return 0; }
  G_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || G_BRANCH=""
  printf '%s' "$G_BRANCH"
}

# =================================================================================================
# ship consent (CONTRACT SS5.7)
# =================================================================================================
# jq is REQUIRED here. This is the fragile-consent-parse fix: a security decision must never rest
# on a sed approximation of JSON, so an absent or broken jq BLOCKS rather than guesses.
# Be honest about what this file is: SHIP_CONSENT is a RECORD that both factors happened, not the
# control. The control is the tool-permission approval plus branch protection on BASE_BRANCH.
g_consent_state() {   # $1 = pr number or "" -> ok | missing | mismatch | unparsable
  local want_pr="${1:-}" pr headsha base answer head
  [ -f "$SHIP_CONSENT" ] || { printf 'missing'; return 0; }
  rt_have_jq || { printf 'unparsable'; return 0; }
  jq -e . "$SHIP_CONSENT" >/dev/null 2>&1 || { printf 'unparsable'; return 0; }
  pr=$(jq -r '.pr // empty'       "$SHIP_CONSENT" 2>/dev/null)
  headsha=$(jq -r '.head_sha // empty' "$SHIP_CONSENT" 2>/dev/null)
  base=$(jq -r '.base // empty'   "$SHIP_CONSENT" 2>/dev/null)
  answer=$(jq -r '.answer // empty' "$SHIP_CONSENT" 2>/dev/null)
  head=$(git rev-parse HEAD 2>/dev/null)
  [ -n "$headsha" ] && [ -n "$head" ] && [ "$headsha" = "$head" ] || { printf 'mismatch'; return 0; }
  [ "$base" = "$BASE_BRANCH" ] || { printf 'mismatch'; return 0; }
  case "$(rt_lc "$answer")" in
    no*|"") printf 'mismatch'; return 0 ;;
    *yes*|*merge*|*approve*|*ship*) ;;
    *) printf 'mismatch'; return 0 ;;
  esac
  if [ -n "$want_pr" ] && [ "$pr" != "$want_pr" ]; then printf 'mismatch'; return 0; fi
  printf 'ok'
}

g_pr_number() {   # first all-digits token after `merge`
  local flag val seen=0
  while IFS=$'\t' read -r flag val; do
    [ -n "$flag" ] || continue
    if [ "$seen" = "1" ]; then
      case "$val" in ''|*[!0-9]*) ;; *) printf '%s' "$val"; return 0 ;; esac
      case "$val" in */pull/*) printf '%s' "${val##*/}"; return 0 ;; esac
    fi
    [ "$val" = "merge" ] && seen=1
  done <<< "$G_TOK"
  return 1
}

# =================================================================================================
# THE RULES - order matters. Write-effect rules come before every read carve-out.
# =================================================================================================
g_check_all() {
  local hit t tl entry

  # -- 0. domain tripwires ------------------------------------------------------------------------
  # Matched against the TARGET view, so the token is caught when it is RUN and not when it is
  # merely described in a commit message. Case-insensitive: --LIVE is --live.
  if [ -n "${FORBIDDEN_EXEC_TOKENS:-}" ]; then
    while IFS= read -r t; do
      t=$(rt_trim "$t"); [ -n "$t" ] || continue
      case "$t" in '#'*) continue ;; esac
      tl=$(rt_lc "$t")
      case "$G_TARGET_LC" in
        *"$tl"*) g_refuse forbidden-exec-tokens \
                   "The command contains a domain-forbidden token: $t" \
                   "FORBIDDEN_EXEC_TOKENS in domain.config.sh names it as an irreversible action." ;;
      esac
    done <<< "$FORBIDDEN_EXEC_TOKENS"
  fi

  # -- 1. banned reads ----------------------------------------------------------------------------
  # Read OR write: the point is that these bytes never enter a context window.
  if [ -n "${BANNED_READ_FILES:-}" ]; then
    if hit=$(g_match_in "$G_TOKENS" "$BANNED_READ_FILES"); then
      g_refuse banned-read-files \
        "The command references a banned file: $hit" \
        "BANNED_READ_FILES names it as context-poisoning - superseded or stale corpus." \
        "Read the current contract instead; it is the one that governs."
    fi
  fi

  # -- 2. secrets ---------------------------------------------------------------------------------
  # Read is as forbidden as write. Exemptions (.env.example) are checked first, inside
  # rt_is_secret_path.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in -*) continue ;; esac
    if rt_is_secret_path "$t"; then
      g_refuse secrets-access \
        "The command touches a secret path: $t" \
        "Secrets are refused on READ as well as write. Credentials reach the process through the" \
        "environment, never through a file the agent opens."
    fi
  done <<< "$G_TOKENS"

  # -- 3. write-EFFECT rules ----------------------------------------------------------------------
  # EVERYTHING BELOW THIS LINE UNTIL 3e USES $G_WRITES, the set of paths the command would WRITE.
  # It is computed from redirects, copy/move/link verbs, in-place rewriters, bulk writers and
  # heredocs - never from an allowlist of "write commands". This block must stay ABOVE any
  # read-verb carve-out: `cat x > .context/SPEC.md` is a corpus write, whatever it starts with.

  # 3a. forbidden artifacts (domain): may never be created or edited
  if [ -n "${FORBIDDEN_ARTIFACTS:-}" ]; then
    if hit=$(g_match_in "$G_WRITES" "$FORBIDDEN_ARTIFACTS"); then
      g_refuse forbidden-artifacts \
        "The command would create or modify a forbidden artifact: $hit" \
        "FORBIDDEN_ARTIFACTS names files whose mere existence changes what the system may do."
    fi
  fi

  # 3b. governing corpus (the human's contracts + harness doctrine): read always, write never
  if hit=$(g_match_in "$G_WRITES" "${GOVERNING_CORPUS:-}"); then
    g_refuse governing-corpus-write \
      "The command would write a governing-corpus file: $hit" \
      "The governing corpus is Tier 2b. Propose the change through the decision log and the" \
      "retrospective; reading it is always allowed, changing it is never the agent's to do."
  fi

  # 3c. the control set: the files that decide what an approval MEANS
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if rt_is_control_set "$t"; then
      g_refuse control-set-write \
        "The command would write a control-layer file: $t" \
        "The control set cannot be changed by the mechanism it implements. That is the property" \
        "that makes the approvable class safe to have at all."
    fi
  done <<< "$G_WRITES"

  # 3d. the escalation store: refusal ledger + approvals
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    rt_repo_rel_var "$t"
    case "$RT_REL/" in
      "$ESCALATIONS_DIR"/*|"$SECRETS_DIR"/*)
        g_refuse escalation-store-write \
          "The command would write the escalation store: $RT_REL" \
          "An agent that can edit the ledger can approve itself. escalate.sh and approve.sh are" \
          "the only writers." ;;
    esac
  done <<< "$G_WRITES"

  # 3e. anything else under .claude/ - refused by default, liftable for ONE byte-exact call
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    rt_repo_rel_var "$t"
    case "$RT_REL/" in
      "$CLAUDE_DIR"/*)
        g_refuse claude-dir-write \
          "The command would write inside $CLAUDE_DIR: $RT_REL" \
          "Agent definitions and non-control hooks are changeable, but never silently." \
          "Prefer a Write tool call with the complete file content: an approval binds to the" \
          "sha256 of the RESULTING FILE, which a redirect or sed -i does not let anyone predict." ;;
    esac
  done <<< "$G_WRITES"

  # -- 4. the human-only approver -----------------------------------------------------------------
  case "$G_TARGET" in
    *approve.sh*)
      g_refuse approve-script-invocation \
        "approve.sh is human-only and is denied to agents at every layer." \
        "You cannot approve your own request - that is the property that makes a request worth" \
        "anything. Ask for it on a Decision Card and let a human run it in their own terminal." ;;
  esac

  # -- 5. git / forge -----------------------------------------------------------------------------
  if g_has_word git || g_has_word gh; then

    # 5a. compound forms. The guard reads the branch and the consent record BEFORE the command
    # runs; a compound form lets the second half act on a state the first half changed.
    case "$G_STRUCT" in
      *'&&'*|*'||'*|*';'*|*'|'*|*'$('*|*'`'*|*$'\n'*)
        g_refuse compound-git-form \
          "A git/gh command was combined with another command." \
          "One command per tool call. The guard evaluates branch and consent state before the" \
          "command runs, and a compound form defeats that by construction." ;;
    esac

    # 5b. force push - never escalatable
    if g_has_word push; then
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
          --force|-f|--force-with-lease|--force-with-lease=*|--force-if-includes|+*:*|--delete|-d)
            g_refuse force-push \
              "History-destroying push detected ($t)." \
              "A force push rewrites history that other work is already based on. There is no" \
              "approval for this: recover the branch instead." ;;
        esac
      done <<< "$G_TOKENS"
    fi

    # 5c. push to BASE_BRANCH - permitted ONLY through the ship flow
    if g_has_word push; then
      local to_base=0 nonflag=0 seen_push=0 flag val
      while IFS=$'\t' read -r flag val; do
        [ -n "$flag" ] || continue
        if [ "$seen_push" = "0" ]; then [ "$val" = "push" ] && seen_push=1; continue; fi
        case "$val" in -*) continue ;; esac
        nonflag=$((nonflag+1))
        case "$val" in
          "$BASE_BRANCH"|*:"$BASE_BRANCH"|refs/heads/"$BASE_BRANCH") to_base=1 ;;
        esac
      done <<< "$G_TOK"
      if [ "$to_base" = "0" ] && [ "$nonflag" -eq 0 ]; then
        # A bare `git push` names no refspec. Where it lands depends on the branch's
        # upstream, on push.default, and on the remote's own refspec config - none of
        # which is in the command, and one of which (push.default=matching) pushes the
        # base branch from any branch. The target is therefore NOT PROVABLE here, and a
        # push is network-visible. Fail closed and make the agent say what it means; the
        # ship flow always pushes explicitly, so this costs a correct caller nothing.
        if [ "$(g_branch)" = "$BASE_BRANCH" ]; then
          to_base=1
        else
          g_refuse push-target-unprovable \
            "A bare 'git push' - the command does not say where it lands." \
            "Where a bare push goes depends on this branch's upstream, on push.default" \
            "(where 'matching' pushes $BASE_BRANCH from any branch), and on the remote's" \
            "refspec. None of that is in the command, so the gate cannot prove this does" \
            "not reach $BASE_BRANCH. Name it: git push -u origin <branch>."
        fi
      fi
      if [ "$to_base" = "1" ]; then
        case "$(g_consent_state "")" in
          ok) : ;;
          unparsable)
            g_refuse ship-consent-unparsable \
              "A push to $BASE_BRANCH was requested but the consent record could not be parsed." \
              "jq is required for this decision; a sed approximation of JSON is not a security" \
              "control. Install jq, or fix $SHIP_CONSENT." ;;
          *)
            g_refuse base-branch-push \
              "A push to $BASE_BRANCH outside the ship flow." \
              "$SHIP_CONSENT must exist and its head_sha must match HEAD, with an affirmative" \
              "Ship Prompt answer. Both factors are required: the card selection is consent, the" \
              "tool-permission approval is the factor you cannot produce, and neither substitutes" \
              "for the other." ;;
        esac
      fi
    fi

    # 5d. commit on BASE_BRANCH - never, consent or not. Work reaches the base branch through the
    # PR, never around it.
    if g_has_word commit && [ "$(g_branch)" = "$BASE_BRANCH" ]; then
      g_refuse base-branch-commit \
        "A commit directly on $BASE_BRANCH." \
        "Work reaches $BASE_BRANCH through the PR, never around it. Branch first."
    fi

    # 5e. gh pr merge - the one irreversible act
    if g_has_word gh && g_has_word merge; then
      local prn; prn=$(g_pr_number) || prn=""
      case "$(g_consent_state "$prn")" in
        ok) : ;;
        unparsable)
          g_refuse ship-consent-unparsable \
            "A merge was requested but the consent record could not be parsed." \
            "jq is required for this decision. Absent jq the guard blocks rather than guesses." ;;
        missing)
          g_refuse ship-consent-missing \
            "A merge was requested with no consent record at $SHIP_CONSENT." \
            "Ask the Ship Prompt with AskUserQuestion, write the record on an affirmative answer," \
            "then re-issue the merge and approve the permission prompt." ;;
        *)
          g_refuse ship-consent-missing \
            "The consent record does not match this merge (pr / head_sha / base / answer)." \
            "A record that does not match HEAD is a record of consent to something else." ;;
      esac
    fi

    # 5f. repository plumbing that silently changes where work goes
    if g_has_word config; then
      local wr=0
      while IFS= read -r t; do
        case "$t" in
          --get|--get-all|--get-regexp|--list|-l|--show-origin) wr=0; break ;;
        esac
      done <<< "$G_TOKENS"
      if g_has_word git; then
        wr=1
        while IFS= read -r t; do
          case "$t" in --get*|--list|-l|--show-origin) wr=0; break ;; esac
        done <<< "$G_TOKENS"
        [ "$wr" = "1" ] && g_refuse git-config-write \
          "git config write detected." \
          "Repository configuration decides identity, hooks and remotes. Changing it moves the" \
          "ground every other guard stands on."
      fi
    fi
    if g_has_word remote && g_has_word git; then
      local rw=0
      while IFS= read -r t; do
        case "$t" in add|remove|rm|rename|set-url|set-head|set-branches|prune) rw=1 ;; esac
      done <<< "$G_TOKENS"
      [ "$rw" = "1" ] && g_refuse git-remote-write \
        "git remote write detected." \
        "Re-pointing a remote sends the work somewhere nobody agreed to."
    fi

    # 5g. --no-verify
    while IFS= read -r t; do
      case "$t" in
        --no-verify) g_refuse no-verify-flag \
            "--no-verify skips the hooks that make the gates mean something." \
            "If a hook is wrong, fix the hook in the open. Bypassing it leaves no record." ;;
      esac
    done <<< "$G_TOKENS"
    if g_has_word commit; then
      while IFS= read -r t; do
        case "$t" in -n) g_refuse no-verify-flag \
            "git commit -n is --no-verify." \
            "If a hook is wrong, fix the hook in the open." ;;
        esac
      done <<< "$G_TOKENS"
    fi
  fi

  # -- 6. inline interpreters ---------------------------------------------------------------------
  # `python -c "..."` is an arbitrary program with no path this guard can inspect. It is the
  # universal bypass for every path rule above.
  local interp=0
  while IFS=$'\t' read -r flag val; do
    [ "${flag:-}" = "P" ] || continue
    case "${val##*/}" in
      python|python3|python2|py|bash|sh|zsh|ksh|dash|perl|ruby|node|nodejs|deno|php|pwsh|powershell)
        interp=1 ;;
    esac
  done <<< "$G_TOK"
  if [ "$interp" = "1" ]; then
    while IFS= read -r t; do
      case "$t" in
        -c|-e|--eval|--command|-E|-Command|-ec|-ce)
          g_refuse inline-interpreter \
            "An inline interpreter invocation ($t) was refused." \
            "An inline program is a path rule with no path to check - it is the general bypass" \
            "for every protection above it. Put the code in a file the guards can see." ;;
      esac
    done <<< "$G_TOKENS"
  fi

  # -- 7. deletions outside the agent scratch dir -------------------------------------------------
  local delv="" a
  for delv in rm rmdir unlink shred; do
    if g_has_word "$delv"; then
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        rt_repo_rel_var "$a"
        case "$RT_REL/" in
          "$PIPELINE_DIR"/*) continue ;;
        esac
        # Scratch under a real temp root is not this repo's evidence, and a control
        # layer that cannot use a temp file is one an agent routes around. Note this
        # is deliberately NOT "anything outside the repo": a repo guard waving through
        # rm on an arbitrary absolute path is a different and worse rule. Secrets are
        # already refused above, before this point.
        case "$a" in
          /tmp/*|/var/tmp/*|/private/tmp/*|"${TMPDIR:-/nonexistent}"/*) continue ;;
        esac
        g_refuse delete-scope \
          "Deletion outside $PIPELINE_DIR/: $RT_REL" \
          "Run-scoped scratch is deletable; everything else is somebody's evidence. Deleting an" \
          "artifact is how a record of what happened stops existing."
      done <<< "$(g_args_after "$delv")"
    fi
  done
  if g_has_word find; then
    while IFS= read -r t; do
      case "$t" in
        -delete|-exec)
          while IFS= read -r a; do
            [ -n "$a" ] || continue
            case "$a" in -*) continue ;; esac
            rt_repo_rel_var "$a"
            case "$RT_REL/" in "$PIPELINE_DIR"/*|./*) continue ;; esac
            g_refuse delete-scope \
              "find with a delete action rooted outside $PIPELINE_DIR/: $RT_REL" \
              "A find -delete is a deletion whose targets nobody enumerated."
          done <<< "$(g_args_after find)"
          break ;;
      esac
    done <<< "$G_TOKENS"
  fi
  if g_has_word git && g_has_word clean; then
    g_refuse delete-scope \
      "git clean deletes untracked files wholesale." \
      "Untracked does not mean unwanted: recorded fixtures, evidence and a half-written plan are" \
      "all untracked at some point in a run."
  fi

  return 0
}

# =================================================================================================
# selftest - every rule below must have an input that makes it fire (CONTRACT SS0.6)
# =================================================================================================
if [ "${1:-}" = "--selftest" ]; then
  # absolute, because the library cd'd us to REPO_ROOT and the child invocations below re-exec it
  _self="$_g_dir/${0##*/}"
  [ -f "$_self" ] || _self="${BASH_SOURCE[0]:-$0}"
  _fails=0
  _run() {  # <expected-rule | ALLOW> <label> <command>
    local exp="$1" label="$2" cmd="$3" rc out got
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(rt_json_escape "$cmd")" \
          | bash "$_self" 2>&1)
    rc=$?
    got=$(printf '%s' "$out" | sed -n 's/.*RATCHET BLOCK \[rule=\([a-z0-9-]*\)\].*/\1/p' | head -n 1)
    [ "$rc" = "0" ] && got="ALLOW"
    if [ "$got" = "$exp" ]; then
      printf '  ok   %-32s %s\n' "$label" "$got"
      return 0
    fi
    printf '  FAIL %-32s expected %s got %s (exit %s) %s\n' "$label" "$exp" "${got:-?}" "$rc" \
           "$(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
    _fails=$((_fails+1))
    return 1
  }
  printf 'guard.sh selftest\n'
  _run ALLOW                   "plain read allowed"       'grep -n foo .context/SPEC.md'
  _run ALLOW                   "scratch delete allowed"   'rm -f .pipeline/run-idle'
  _run ALLOW                   "ordinary command allowed" 'ls -la docs'
  _run ALLOW                   "read-only git allowed"    'git log --oneline -n 5'
  _run governing-corpus-write  "redirect into corpus"     'cat notes.md > .context/SPEC.md'
  _run governing-corpus-write  "tee into corpus"          'tee .context/MILESTONES.md'
  _run governing-corpus-write  "sed -i on corpus"         'sed -i s/a/b/ .context/SPEC.md'
  _run control-set-write       "cp over control set"      'cp /tmp/x .claude/hooks/guard.sh'
  _run claude-dir-write        "write under .claude"      'echo x > .claude/agents/scout.md'
  _run secrets-access          "secret read"              'cat secrets/escalation.key'
  _run secrets-access          "dotenv read"              'grep TOKEN .env'
  _run force-push              "force push"               'git push --force origin agent/x'
  _run ship-consent-missing    "merge without consent"    'gh pr merge 42 --squash'
  _run compound-git-form       "compound git"             'git add -A && git commit -m x'
  _run inline-interpreter      "inline interpreter"       'python -c "print(1)"'
  _run delete-scope            "delete outside scratch"   'rm -rf docs/evidence'
  _run no-verify-flag          "no-verify"                'git commit --no-verify -m x'
  _run git-config-write        "git config write"         'git config user.email a@b.c'
  _run git-remote-write        "git remote write"         'git remote set-url origin http://x'
  _run approve-script-invocation "approve.sh invocation"  '.claude/hooks/approve.sh abc'
  _run unparsable-command      "unterminated quote"       'echo "oops'
  _run delete-scope            "git clean"                'git clean -fd'
  # the two-view parser: prose in a message is not a target, a quoted path still is
  _run ALLOW                   "corpus named in a message" 'git tag -m "regenerate .context/SPEC.md" v1'
  _run secrets-access          "quoted secret is a target" 'cat "secrets/api.key"'
  _run escalation-store-write  "escalation ledger write"  'echo x >> .pipeline/escalations/ledger.jsonl'

  # domain wiring: with an empty domain pack these three cannot fire, so inject a domain.
  _runenv() {  # <env-assignment> <expected-rule> <label> <command>
    local env1="$1"; shift
    # the subshell keeps the injected domain out of the other cases; its _fails is lost, so the
    # exit status is what carries the verdict back
    if ! ( eval "export $env1"; _run "$@" ); then _fails=$((_fails+1)); fi
    return 0
  }
  _runenv "FORBIDDEN_EXEC_TOKENS=--live"      forbidden-exec-tokens \
          "domain exec token"        'deploy --live'
  _runenv "FORBIDDEN_ARTIFACTS=LIVE_CONFIRMED" forbidden-artifacts \
          "domain artifact"          'touch LIVE_CONFIRMED'
  _runenv "BANNED_READ_FILES=docs/old-dump.md" banned-read-files \
          "domain banned read"       'cat docs/old-dump.md'
  # Branch- and consent-dependent rules (base-branch-push, base-branch-commit,
  # ship-consent-missing, ship-consent-unparsable) need a repo whose HEAD is on BASE_BRANCH; they
  # are covered by the id-coverage check below and by test_hooks.py against a scratch repo.

  # The rule vocabulary must be exactly the set of ids this file can emit, in BOTH directions:
  # an emitted id missing from rt_rule_ids is a rule the escalation classifier never saw; a
  # declared id nobody emits is a rule that cannot fire, which CONTRACT SS0.6 forbids.
  _declared=$(rt_rule_ids)
  _used=$(grep -v '^[[:space:]]*#' "$_self" \
          | grep -oE 'g_refuse [a-z][a-z0-9-]+' | awk '{print $2}' | sort -u)
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

  [ "$_fails" -gt 0 ] && { printf 'guard.sh selftest: %s FAILURE(S)\n' "$_fails" >&2; exit 1; }
  printf 'guard.sh selftest: OK\n'
  exit 0
fi

# =================================================================================================
g_analyse
g_check_all
rt_log_cmd "Bash" "ALLOW" "-" "" "$CMD"
exit 0
