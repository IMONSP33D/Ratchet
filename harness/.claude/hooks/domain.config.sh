#!/usr/bin/env bash
# domain.config.sh - THE DOMAIN PACK. *** THIS IS THE FILE A HUMAN (or the init interview) EDITS. ***
# Everything project-specific in Ratchet lives here and nowhere else; no other harness file may
# contain a project noun. Rewriting this file re-points every guard at a new domain.
# ------------------------------------------------------------------------------------------------
# Shipped state: the EMPTY domain ("none"). Every list is empty EXCEPT the two the harness cannot
# safely run without - GOVERNING_CORPUS (the human-owned contracts) and SECRET_PATTERNS.
# Empty lists are VALID (CONTRACT SS2.2): the harness still protects secrets, the governing corpus
# and the control layer. Filling a list only ever ADDS refusals.
#
# FORMAT RULES (all lists):
#   * One entry per line inside a quoted here-string. Blank lines and #-comments are ignored.
#   * Entries are matched four ways, in this order, against the repo-relative POSIX path:
#       exact path        .context/SPEC.md
#       directory prefix  secrets/            (trailing slash = everything under it)
#       bare filename     LIVE_CONFIRMED      (matches that basename anywhere in the tree)
#       glob              *.pem  .env.*  id_rsa*
#   * Matching is case-insensitive for FORBIDDEN_EXEC_TOKENS, case-sensitive for paths.
#   * Never put a regex here. These are globs, not regexes.
#
# This file is SOURCED. It sets no shell options and runs no commands.
# Run `bash domain.config.sh --selftest` to print the resolved lists.
# ------------------------------------------------------------------------------------------------

# --- identity ------------------------------------------------------------------------------------
# Short label used in prompts, the recap and pager payloads. "none" = the generic harness.
DOMAIN_NAME="${DOMAIN_NAME:-none}"

# --- FORBIDDEN_EXEC_TOKENS -------------------------------------------------------------------------
# Substrings that must NEVER appear in a Bash command. guard.sh matches these case-insensitively
# against the TARGET VIEW of the command (rt_strip_msg: the prose payload of -m/--message/--body/-F
# is removed first, so writing the word in a commit message is not a refusal - running it is).
# This is the domain's tripwire list: the irreversible verbs of your problem space.
# Rule id emitted: forbidden-exec-tokens
FORBIDDEN_EXEC_TOKENS="${FORBIDDEN_EXEC_TOKENS:-}"

# --- FORBIDDEN_ARTIFACTS ---------------------------------------------------------------------------
# Files the agent may never create or edit, by path or basename. Checked on WRITE EFFECT only
# (a redirect, a copy/move/link, tee, sed -i, dd, truncate, patch, a heredoc, or an Edit/Write tool
# call) - reading one is allowed, manufacturing one is not.
# Rule id emitted: forbidden-artifacts
FORBIDDEN_ARTIFACTS="${FORBIDDEN_ARTIFACTS:-}"

# --- BANNED_READ_FILES -----------------------------------------------------------------------------
# Context-poisoning files: superseded corpora, giant dumps, stale full-view specs. Any mention of
# one in a Bash command is refused, read or not - the point is that its bytes never enter a context
# window. Put the file's real path here; a rule that names a file which does not exist teaches
# nothing and hides the one that matters.
# Rule id emitted: banned-read-files
BANNED_READ_FILES="${BANNED_READ_FILES:-}"

# --- GOVERNING_CORPUS ------------------------------------------------------------------------------
# The human-owned contracts (Tier 2b). Agents READ these constantly and may never WRITE them.
# Never-escalatable: no approval, card or domain pack lifts a write refusal here.
# Rule id emitted: governing-corpus-write
#
# NOTE on DECISIONS.md - deliberately NOT in this list. CONTRACT SS7.3 requires that "appending a
# decision must never be the failing action": over the hot-file hard cap the checker emits
# ROLLOVER-REQUIRED and the guard still permits the append. Adding DECISIONS.md here would make the
# decision log unwritable and strand every ambiguity the agent is required to log.
GOVERNING_CORPUS="${GOVERNING_CORPUS:-.context/CLAUDE.md
.context/PIPELINE.md
.context/TEMPLATE.md
.context/SPEC.md
.context/MILESTONES.md}"

# --- SECRET_PATTERNS -------------------------------------------------------------------------------
# Secrets are refused on READ as well as write, in Bash and in Edit/Write. Never-escalatable.
# Rule id emitted: secrets-access
SECRET_PATTERNS="${SECRET_PATTERNS:-.env
.env.*
secrets/
*.pem
*.key
*.p8
id_rsa*}"

# --- SECRET_EXEMPTIONS -----------------------------------------------------------------------------
# Checked BEFORE SECRET_PATTERNS. These are the committed, deliberately-empty templates.
# Keep this list short: every entry is a hole in the secrets wall.
SECRET_EXEMPTIONS="${SECRET_EXEMPTIONS:-.env.example
.env.sample}"

# --- SECURITY_BOUNDARY_FILES -----------------------------------------------------------------------
# Hard Stop 1 files: the auth boundary, key storage, the redaction filter. These are not blanket-
# denied (building them per spec is sanctioned work); they are the files whose modification the
# reviewer and security-auditor are told to treat as security-relevant, and which auto-promote a
# fast checkpoint to full.
SECURITY_BOUNDARY_FILES="${SECURITY_BOUNDARY_FILES:-}"

# --- DOMAIN_NEVER_ESCALATABLE ----------------------------------------------------------------------
# Extra RULE IDS (not paths) that can never be lifted by an approval, on top of the harness-fixed
# core in CONTRACT SS5.6. Use rule ids exactly as guard.sh/scope-guard.sh emit them; both scripts
# print their full id list with `--list-rules`, so a typo here is mechanically detectable.
DOMAIN_NEVER_ESCALATABLE="${DOMAIN_NEVER_ESCALATABLE:-}"

# --- DOMAIN_LAWS -----------------------------------------------------------------------------------
# Markdown injected verbatim as laws 3-6 into every agent definition (laws 1, 2 and 7 are
# harness-fixed: TDD, milestone gates, the deterministic verify gate). Write them as imperatives a
# reviewer can check a diff against, not as values.
DOMAIN_LAWS="${DOMAIN_LAWS:-}"

# --- DOMAIN_REVIEW_LENS ----------------------------------------------------------------------------
# Markdown injected into the reviewer seat: the domain-specific correctness questions.
DOMAIN_REVIEW_LENS="${DOMAIN_REVIEW_LENS:-}"

# --- DOMAIN_SECURITY_PASS --------------------------------------------------------------------------
# Markdown injected into the security-auditor seat: the domain-specific attacker questions.
DOMAIN_SECURITY_PASS="${DOMAIN_SECURITY_PASS:-}"

# --- ARBITER_LABEL ---------------------------------------------------------------------------------
# The "Escalate to <X>" option label offered on Decision Cards.
ARBITER_LABEL="${ARBITER_LABEL:-Escalate to a higher-tier model}"

# ==================================================================================================
# WORKED EXAMPLE - a filled domain pack, commented out. Uncomment/adapt, or let the init interview
# generate the equivalent. The example is an order-placing exchange client whose live-order path
# must be unreachable by any agent; the shape transfers to any domain with an irreversible action
# (a deploy, a publish, a customer-data delete, an outbound send).
# ==================================================================================================
#
# DOMAIN_NAME="exchange-bot"
#
# # The irreversible verbs. Anything that could place a real order or point at production.
# FORBIDDEN_EXEC_TOKENS="--live
# --real-money
# LIVE_CONFIRMED
# api.exchange.example.com
# ENABLE_LIVE=1
# place_live_order"
#
# # The two files whose mere existence would arm live mode.
# FORBIDDEN_ARTIFACTS="LIVE_CONFIRMED
# HUMAN_APPROVAL.md"
#
# # A superseded 400KB full-corpus dump. Loading it poisons context with stale requirements.
# BANNED_READ_FILES=".context/archive/legacy-master-spec.md"
#
# GOVERNING_CORPUS=".context/CLAUDE.md
# .context/PIPELINE.md
# .context/TEMPLATE.md
# .context/SPEC.md
# .context/MILESTONES.md"
#
# SECRET_PATTERNS=".env
# .env.*
# secrets/
# *.pem
# *.key
# *.p8
# id_rsa*
# config/credentials.*"
#
# SECRET_EXEMPTIONS=".env.example
# .env.sample"
#
# SECURITY_BOUNDARY_FILES="src/billing/gateway_auth.py
# src/billing/key_store.py
# src/logging/redaction.py"
#
# # Two extra ids the domain refuses to ever let an approval lift.
# DOMAIN_NEVER_ESCALATABLE="forbidden-exec-tokens
# forbidden-artifacts"
#
# DOMAIN_LAWS='3. **Sandbox only. The production charge path is unreachable by agents.** All work
#    targets the sandbox gateway. The production triple-gate is Tier 2b: nothing can authorize an
#    agent to create or satisfy it.
# 4. **Amounts are integer minor units.** Never `float` for an amount; `Decimal` only for
#    intermediate rate math, rounded exactly once at the boundary.
# 5. **Config, not literals.** Account ids, rate coefficients, URLs and limits live in config;
#    volatile external facts sit in the assumption register and are verified, not assumed.
# 6. **No secrets, ever.** Credentials via env only; keys mode 0600 outside the repo; a redaction
#    filter on every log sink.'
#
# DOMAIN_REVIEW_LENS='- Does any amount path touch a float, at any point, including a test helper?
# - Is every charge computed inclusive of the gateway rounding rule, and rounded exactly once?
# - Does any code path reach a production endpoint, transitively, including via config defaults?'
#
# DOMAIN_SECURITY_PASS='- Could a malformed gateway response drive an unbounded charge amount?
# - Is any credential reachable from a log line, an exception string, or a recorded fixture?
# - Does a recorded fixture still carry a real account id after scrubbing?'
#
# ARBITER_LABEL="Escalate to Arbiter"
#
# ==================================================================================================

# --- selftest ----------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  printf 'domain.config.sh selftest\n  DOMAIN_NAME=%s\n' "$DOMAIN_NAME"
  for _v in FORBIDDEN_EXEC_TOKENS FORBIDDEN_ARTIFACTS BANNED_READ_FILES GOVERNING_CORPUS \
            SECRET_PATTERNS SECRET_EXEMPTIONS SECURITY_BOUNDARY_FILES DOMAIN_NEVER_ESCALATABLE \
            DOMAIN_LAWS DOMAIN_REVIEW_LENS DOMAIN_SECURITY_PASS ARBITER_LABEL; do
    eval "_val=\${$_v-__UNSET__}"
    if [ "$_val" = "__UNSET__" ]; then
      printf '  FAIL: %s is not defined\n' "$_v" >&2; exit 1
    fi
    _n=$(printf '%s\n' "$_val" | grep -c '[^[:space:]]' 2>/dev/null); _n=${_n:-0}
    printf '  %-26s %s non-empty line(s)\n' "$_v" "$_n"
  done
  # The two lists the harness must never ship empty.
  for _v in GOVERNING_CORPUS SECRET_PATTERNS; do
    eval "_val=\${$_v:-}"
    case "$_val" in *[!\ \	]*) : ;; *) printf '  FAIL: %s must not be empty\n' "$_v" >&2; exit 1 ;; esac
  done
  printf '  OK\n'
  exit 0
fi
