#!/usr/bin/env bash
# ============================================================================
# interview.sh — the Ratchet DOMAIN PACK interview.
#
# YOU (a human) RUN THIS. It asks what your project's dangerous edges are and
# writes .claude/hooks/domain.config.sh — the only file in the harness that
# knows anything about your domain.
#
# WHAT IT PRODUCES (CONTRACT §2.2, frozen names):
#   DOMAIN_NAME  FORBIDDEN_EXEC_TOKENS  FORBIDDEN_ARTIFACTS  BANNED_READ_FILES
#   GOVERNING_CORPUS  SECRET_PATTERNS  SECRET_EXEMPTIONS  SECURITY_BOUNDARY_FILES
#   DOMAIN_NEVER_ESCALATABLE  DOMAIN_LAWS  DOMAIN_REVIEW_LENS
#   DOMAIN_SECURITY_PASS  ARBITER_LABEL
#
# EMPTY IS A VALID ANSWER TO EVERY QUESTION. A project with no dangerous
# irreversible action ("--domain none") still gets the whole harness: the
# control layer, the governing corpus, secrets protection and the ship gate are
# harness-fixed and do not come from here. The domain pack only ADDS walls.
#
# SAFE TO RE-RUN. An existing domain.config.sh is read first and every answer
# you already gave becomes the default, so re-running to change one thing costs
# you one answer and a lot of Enter. The old file is backed up before write.
#
# Usage:
#   .claude/hooks/interview.sh                     interactive
#   .claude/hooks/interview.sh --non-interactive   accept every default, write, exit
#   .claude/hooks/interview.sh --output <path>     write somewhere else
#   .claude/hooks/interview.sh --print             show what it would write, write nothing
#
# Exit codes: 0 wrote (or printed); 2 refused (bad args, unwritable target).
# ============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SELF_DIR="."
OUT="$SELF_DIR/domain.config.sh"
NONINTERACTIVE=0
PRINT_ONLY=0

die() { printf 'interview: %s\n' "$*" >&2; exit 2; }
# Every conversational byte goes to stderr. stdout carries the generated pack
# and nothing else, so `interview.sh --print > domain.config.sh` is a correct
# thing to type rather than a trap that writes prose into a shell file.
say()  { printf '%s\n' "$*" >&2; }
rule() { printf '%s\n' "------------------------------------------------------------------" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive|-n) NONINTERACTIVE=1 ;;
    --print)              PRINT_ONLY=1 ;;
    --output)             shift; [ $# -gt 0 ] || die "--output needs a path"; OUT="$1" ;;
    --output=*)           OUT="${1#--output=}" ;;
    -h|--help)            sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                    die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# No terminal means no interview. An installer running unattended must never
# block on a read that nobody will answer -- that is the same indefinite stall
# the permission-prompt doctrine exists to avoid, arriving by a different door.
# RATCHET_INTERVIEW_ASSUME_TTY=1 forces the prompt loops so they can be driven
# from a fixture file in a test; it is a test seam, not a supported mode.
if [ ! -t 0 ] && [ "${RATCHET_INTERVIEW_ASSUME_TTY:-0}" != "1" ]; then
  NONINTERACTIVE=1
fi

# --------------------------------------------------------------- prefill ----
# Source an existing pack so every prior answer becomes this run's default.
# Sourced in a subshell-safe way: we only care about the frozen variable names.
DOMAIN_NAME=""; FORBIDDEN_EXEC_TOKENS=""; FORBIDDEN_ARTIFACTS=""
BANNED_READ_FILES=""; GOVERNING_CORPUS=""; SECRET_PATTERNS=""
SECRET_EXEMPTIONS=""; SECURITY_BOUNDARY_FILES=""; DOMAIN_NEVER_ESCALATABLE=""
DOMAIN_LAWS=""; DOMAIN_REVIEW_LENS=""; DOMAIN_SECURITY_PASS=""; ARBITER_LABEL=""
PROJECT_NAME="${PROJECT_NAME:-}"
HAD_EXISTING=0
if [ -f "$OUT" ]; then
  # shellcheck disable=SC1090
  . "$OUT" 2>/dev/null && HAD_EXISTING=1
fi

# Harness-wide defaults for the "you almost certainly want these" answers.
: "${GOVERNING_CORPUS:=.context/CLAUDE.md
.context/PIPELINE.md
.context/CONVENTIONS.md
.context/SPEC.md
.context/MILESTONES.md
CLAUDE.md}"
: "${SECRET_PATTERNS:=.env
.env.*
secrets/**
*.pem
*.key
*.p8
*.pfx
id_rsa
id_ed25519}"
: "${SECRET_EXEMPTIONS:=.env.example
.env.sample
.env.template}"
: "${ARBITER_LABEL:=Escalate to a higher-tier model}"
: "${DOMAIN_NAME:=none}"

# ------------------------------------------------------------------ ask -----
# ask <varname> <prompt> [default]
ask() {
  local __var="$1" __prompt="$2" __def="${3-}" __ans=""
  eval "__def=\"\${$__var:-\$__def}\""
  if [ "$NONINTERACTIVE" = "1" ]; then
    eval "$__var=\$__def"
    return 0
  fi
  printf '\n%s\n' "$__prompt" >&2
  if [ -n "$__def" ]; then printf '  [%s] > ' "$__def" >&2; else printf '  [none] > ' >&2; fi
  IFS= read -r __ans || __ans=""
  __ans="${__ans%$'\r'}"
  [ -n "$__ans" ] || __ans="$__def"
  eval "$__var=\$__ans"
}

# ask_list <varname> <prompt> — one item per line, blank line ends.
ask_list() {
  local __var="$1" __prompt="$2" __cur="" __line="" __acc=""
  eval "__cur=\${$__var:-}"
  if [ "$NONINTERACTIVE" = "1" ]; then return 0; fi
  printf '\n%s\n' "$__prompt" >&2
  if [ -n "$__cur" ]; then
    printf '  current:\n' >&2
    printf '%s\n' "$__cur" | sed 's/^/    /' >&2
    printf '  Enter on the FIRST line keeps the current list. Type "-" to clear it.\n' >&2
  fi
  printf '  One per line; blank line ends.\n' >&2
  local __first=1
  while :; do
    printf '  > ' >&2
    IFS= read -r __line || break
    __line="${__line%$'\r'}"
    if [ -z "$__line" ]; then
      if [ "$__first" = "1" ]; then eval "$__var=\$__cur"; return 0; fi
      break
    fi
    if [ "$__line" = "-" ] && [ "$__first" = "1" ]; then eval "$__var=''"; return 0; fi
    __acc="${__acc:+$__acc$'\n'}$__line"
    __first=0
  done
  eval "$__var=\$__acc"
}

# ask_block <varname> <prompt> — multi-line markdown, terminated by a lone "."
ask_block() {
  local __var="$1" __prompt="$2" __cur="" __line="" __acc="" __first=1
  eval "__cur=\${$__var:-}"
  if [ "$NONINTERACTIVE" = "1" ]; then return 0; fi
  printf '\n%s\n' "$__prompt" >&2
  if [ -n "$__cur" ]; then
    printf '  current:\n' >&2
    printf '%s\n' "$__cur" | sed 's/^/    /' >&2
    printf '  Enter on the FIRST line keeps it. Type "-" to clear it.\n' >&2
  fi
  printf '  Markdown, multiple lines. End with a single "." on its own line.\n' >&2
  while :; do
    printf '  | ' >&2
    IFS= read -r __line || break
    __line="${__line%$'\r'}"
    if [ "$__line" = "." ]; then break; fi
    if [ -z "$__line" ] && [ "$__first" = "1" ]; then eval "$__var=\$__cur"; return 0; fi
    if [ "$__line" = "-" ] && [ "$__first" = "1" ]; then eval "$__var=''"; return 0; fi
    __acc="${__acc:+$__acc$'\n'}$__line"
    __first=0
  done
  eval "$__var=\$__acc"
}

yesno() { # yesno <prompt> <default y|n> -> exit 0 for yes
  local __p="$1" __d="${2:-n}" __a=""
  if [ "$NONINTERACTIVE" = "1" ]; then [ "$__d" = "y" ]; return $?; fi
  printf '\n%s [%s/%s] > ' "$__p" \
    "$( [ "$__d" = y ] && echo Y || echo y )" "$( [ "$__d" = y ] && echo n || echo N )" >&2
  IFS= read -r __a || __a=""
  __a="${__a%$'\r'}"
  [ -n "$__a" ] || __a="$__d"
  case "$__a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- intro -----
if [ "$NONINTERACTIVE" != "1" ]; then
  rule
  say "RATCHET — domain pack interview"
  rule
  say "Nine questions. Every one may be answered with Enter (keep the default) or"
  say "left empty. An empty domain pack is valid and common: it means \"this project"
  say "has no irreversible action that needs its own wall\", and you still get the"
  say "control layer, the governing corpus, secrets protection and the ship gate."
  say ""
  if [ "$HAD_EXISTING" = "1" ]; then
    say "Found an existing pack at $OUT — your previous answers are the defaults."
  fi
fi

# 1 -------------------------------------------------------------------------
ask PROJECT_NAME \
  "1/9  Project name (the human label used in pager payloads and the recap):" \
  "$(basename "$(cd "$SELF_DIR/../.." 2>/dev/null && pwd || echo project)")"

ask DOMAIN_NAME \
  "     Short domain label (one word; \"none\" is fine):" "$DOMAIN_NAME"

# 2 -------------------------------------------------------------------------
HAS_DANGER=n
if [ -n "$FORBIDDEN_EXEC_TOKENS$FORBIDDEN_ARTIFACTS" ]; then HAS_DANGER=y; fi
if yesno "2/9  Is there an IRREVERSIBLE or DANGEROUS action in this project that an
     agent must never take? (money moving, production deploy, sending mail,
     deleting customer data, publishing a package, charging a card...)" "$HAS_DANGER"; then

  ask_list FORBIDDEN_EXEC_TOKENS \
"     Exec tokens: substrings that must NEVER appear in a command the agent runs.
     Be literal and be generous — these are matched as substrings against the
     structural view of the command, so a token like \"--live\" also catches
     \"--live-run\". Examples: --live  --prod  deploy:production  npm publish
     terraform apply  stripe charge"

  ask_list FORBIDDEN_ARTIFACTS \
"     Artifact filenames the agent may never create or edit — the files that,
     by existing, authorise the dangerous thing. These become deny entries in
     settings.json AND a refusal in scope-guard.sh, two layers, never liftable.
     Examples: LIVE_CONFIRMED  HUMAN_APPROVAL.md  .prod-enabled"
else
  FORBIDDEN_EXEC_TOKENS=""
  FORBIDDEN_ARTIFACTS=""
fi

# 3 -------------------------------------------------------------------------
ask LAW4_INVARIANT \
"3/9  Your domain's SACRED INVARIANT — becomes law 4, quoted in every agent.
     One sentence, stated so a reviewer can catch a violation by reading a diff.
     Examples: \"Amounts are integer minor units; never float for money.\"
     \"Every user-facing string goes through i18n; no literals in components.\"
     \"No query runs without an explicit tenant_id filter.\"" \
  "${LAW4_INVARIANT:-}"

# 4 -------------------------------------------------------------------------
ask LAW5_NOHARDCODE \
"4/9  What must NEVER be hardcoded — becomes law 5.
     Examples: \"Endpoints, feature limits and pricing coefficients live in
     config, never in source.\"" \
  "${LAW5_NOHARDCODE:-}"

# 5 -------------------------------------------------------------------------
ask LAW6_CREDENTIALS \
"5/9  Where credentials live — becomes law 6.
     Examples: \"Credentials via environment only; key files mode 0600 outside
     the repo; a redaction filter on every log sink.\"" \
  "${LAW6_CREDENTIALS:-Credentials come from the environment only. No key, token or password is ever written into the repository, a fixture, or a log.}"

# 6 -------------------------------------------------------------------------
ask_list SECURITY_BOUNDARY_FILES \
"6/9  Security-boundary files. Touching one of these is Hard Stop 1: the run
     PAUSES BEFORE the edit rather than after it. Name the files where your auth,
     signing, session or crypto lives.
     Examples: src/auth.py  src/session.py  src/crypto/**"

# 7 -------------------------------------------------------------------------
ask_list BANNED_READ_FILES \
"7/9  Context-poisoning files the agent must never READ. Superseded specs, giant
     dumps, stale corpora. A rule naming a file that does not exist teaches
     nothing — check the path before you type it.
     Examples: .context/archive/old-full-spec.md"

ask_list GOVERNING_CORPUS \
"     Governing corpus — human-owned documents the agent may never edit.
     The five .context/ documents plus root CLAUDE.md are the default; add any
     other doc that is a contract rather than a note."

# 8 -------------------------------------------------------------------------
ask_list DOMAIN_NEVER_ESCALATABLE \
"8/9  Extra NEVER-ESCALATABLE rule ids. The harness already makes these never:
     secrets, force push, base-branch push outside the ship flow, the governing
     corpus, and the control set. Add a rule id here only if lifting it could
     cause harm no revert undoes. Nothing you add here can ever be approved —
     not by you, not by a card, not by a domain pack.
     Examples: live-exec  prod-deploy"

ask_list SECRET_PATTERNS \
"     Secret patterns (glob-ish). Default covers .env, secrets/, and the usual
     key extensions. Add anything project-specific."

ask_list SECRET_EXEMPTIONS \
"     Secret exemptions — files that LOOK like secrets and are safe (.env.example
     and friends)."

# 9 -------------------------------------------------------------------------
ask ARBITER_LABEL \
"9/9  Arbiter label — the third option on every Decision Card, the way you buy a
     higher-tier opinion without having to form one yourself. It appears
     verbatim as a card option." \
  "$ARBITER_LABEL"

ask_block DOMAIN_REVIEW_LENS \
"     Review lens (optional): extra questions the reviewer must ask of this
     domain's code. Injected into the reviewer agent."

ask_block DOMAIN_SECURITY_PASS \
"     Security pass (optional): extra checks the security auditor must run for
     this domain. Injected into the security-auditor agent."

# ------------------------------------------------------- assemble the laws --
# Laws 1, 2 and 7 are harness-fixed and live in _LAWS.md. Laws 3-6 are yours.
LAW3=""
if [ -n "$FORBIDDEN_EXEC_TOKENS$FORBIDDEN_ARTIFACTS" ]; then
  _tok="$(printf '%s' "$FORBIDDEN_EXEC_TOKENS" | sed '/^$/d' | tr '\n' ' ')"
  _art="$(printf '%s' "$FORBIDDEN_ARTIFACTS"   | sed '/^$/d' | tr '\n' ' ')"
  LAW3="3. **The dangerous action is unreachable by agents.** No agent may run a command containing${_tok:+ \`${_tok% }\`}, nor create, edit or satisfy${_art:+ \`${_art% }\`}. These are never-escalatable: nothing authorises an agent past them — not an approval, not a Decision Card, not a domain pack. A run that believes it needs one has hit a Hard Stop, and a human acts."
else
  LAW3="3. **Reversibility first.** This project declared no walled-off irreversible action. That is a statement about today, not a licence: any act that cannot be undone by a revert — publishing, deploying, sending, spending, deleting another system's data — is outside every plan until a human puts it in one, and adding it means re-running the domain interview, not arguing in a task message."
fi

LAW4="4. **${LAW4_INVARIANT%%.}.** This is the domain's sacred invariant. A diff that breaks it is wrong even when every test is green, because the tests are downstream of it."
if [ -z "${LAW4_INVARIANT:-}" ]; then
  LAW4="4. **No sacred invariant declared.** The domain interview recorded none. Until one is named, treat correctness as defined solely by the SPEC requirement ids — and if you find yourself relying on an unwritten rule to judge a diff, that rule is the missing law and it belongs in the interview, not in your head."
fi

LAW5="5. **${LAW5_NOHARDCODE:-Config, not literals.}** Volatile facts live in configuration and are verified, not assumed. A literal in source is a fact nobody will ever re-check."
LAW6="6. **${LAW6_CREDENTIALS}** No secret reaches a commit, a fixture, a log line, or a pager payload."

DOMAIN_LAWS="$LAW3
$LAW4
$LAW5
$LAW6"

# Three prose markers the doctrine documents consume. They are derived, not
# asked, because every one of them is a restatement of an answer above and a
# second question would be a second chance to disagree with yourself.
if [ "$DOMAIN_NAME" = "none" ] || [ -z "$DOMAIN_NAME" ]; then
  DOMAIN_DESCRIPTION="${DOMAIN_DESCRIPTION:-a software project with no declared domain pack}"
else
  DOMAIN_DESCRIPTION="${DOMAIN_DESCRIPTION:-a $DOMAIN_NAME project}"
fi

if [ -n "${LAW4_INVARIANT:-}" ]; then
  DOMAIN_MATERIALITY="${DOMAIN_MATERIALITY:-it changes the domain invariant (${LAW4_INVARIANT%.}) in a way a later milestone inherits}"
else
  DOMAIN_MATERIALITY="${DOMAIN_MATERIALITY:-it changes a rule that later milestones will inherit rather than re-derive}"
fi

if [ -n "$FORBIDDEN_EXEC_TOKENS$FORBIDDEN_ARTIFACTS" ]; then
  _htok="$(printf '%s' "$FORBIDDEN_EXEC_TOKENS" | sed '/^$/d' | tr '\n' ' ')"
  _hart="$(printf '%s' "$FORBIDDEN_ARTIFACTS"   | sed '/^$/d' | tr '\n' ' ')"
  DOMAIN_HARD_STOPS="${DOMAIN_HARD_STOPS:-Specifically for this domain: any command containing ${_htok:-<none>}, and any attempt to create, edit or satisfy ${_hart:-<none>}.}"
else
  DOMAIN_HARD_STOPS="${DOMAIN_HARD_STOPS:-This domain declared no additional irreversible action; the harness-fixed list above is the whole wall.}"
fi

# --------------------------------------------------------------- emit -------
q() { # shell-single-quote a value safely
  printf "'%s'" "$(printf '%s' "${1-}" | sed "s/'/'\\\\''/g")"
}

TMPOUT="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/ratchet-domain.$$")"
{
  cat <<'HDR'
#!/usr/bin/env bash
# ============================================================================
# domain.config.sh — Ratchet DOMAIN PACK.  GENERATED by interview.sh.
#
# HUMANS EDIT THIS FILE. Re-run .claude/hooks/interview.sh to regenerate it
# (your current answers become the defaults, so changing one thing is cheap),
# or edit it here by hand — it is a plain shell file and nothing rewrites it
# behind your back.
#
# This is the ONLY file in the harness that knows what your project is about.
# Everything else is domain-blind on purpose. Empty values are valid and
# degrade cleanly: the control layer, the governing corpus, secrets protection
# and the ship gate do not come from here.
#
# List variables are NEWLINE-separated. Order does not matter. Blank lines are
# ignored by every reader.
# ============================================================================
HDR
  # Every assignment is written in ${VAR:-default} form so an environment
  # variable still wins. That matters more than it looks: it is how a CI job
  # tightens one wall for one run without editing a tracked file, and it is the
  # convention the rest of the config layer already uses.
  emit_scalar() { printf '%s="${%s:-%s}"\n' "$1" "$1" "$(printf '%s' "${2-}" | sed 's/[\\"$`]/\\&/g')"; }
  emit_block() {
    local __n="$1" __v
    __v="$(printf '%s' "${2-}" | sed '/^[[:space:]]*$/d')"
    printf 'if [ -z "${%s:-}" ]; then %s=$(cat <<'"'"'RT_EOF'"'"'\n%s\nRT_EOF\n); fi\n\n' "$__n" "$__n" "$__v"
  }

  printf '\n# --- identity --------------------------------------------------------------\n'
  emit_scalar DOMAIN_NAME        "$DOMAIN_NAME"
  emit_scalar PROJECT_NAME       "$PROJECT_NAME"
  emit_scalar ARBITER_LABEL      "$ARBITER_LABEL"
  emit_scalar DOMAIN_DESCRIPTION "$DOMAIN_DESCRIPTION"
  printf '\n# --- walls (newline lists; empty is valid) ---------------------------------\n'
  for v in FORBIDDEN_EXEC_TOKENS FORBIDDEN_ARTIFACTS BANNED_READ_FILES \
           GOVERNING_CORPUS SECRET_PATTERNS SECRET_EXEMPTIONS \
           SECURITY_BOUNDARY_FILES DOMAIN_NEVER_ESCALATABLE; do
    eval "_val=\${$v:-}"
    emit_block "$v" "$_val"
  done
  printf '# --- laws 3-6 (laws 1, 2 and 7 are harness-fixed in _LAWS.md) --------------\n'
  emit_block DOMAIN_LAWS "$DOMAIN_LAWS"
  printf '# --- prose injected into the doctrine documents ----------------------------\n'
  emit_block DOMAIN_MATERIALITY "${DOMAIN_MATERIALITY:-}"
  emit_block DOMAIN_HARD_STOPS  "${DOMAIN_HARD_STOPS:-}"
  printf '# --- prose injected into agent definitions ---------------------------------\n'
  emit_block DOMAIN_REVIEW_LENS   "${DOMAIN_REVIEW_LENS:-}"
  emit_block DOMAIN_SECURITY_PASS "${DOMAIN_SECURITY_PASS:-}"
  printf '# --- raw interview answers (kept so a re-run can prefill) ------------------\n'
  emit_scalar LAW4_INVARIANT   "${LAW4_INVARIANT:-}"
  emit_scalar LAW5_NOHARDCODE  "${LAW5_NOHARDCODE:-}"
  emit_scalar LAW6_CREDENTIALS "${LAW6_CREDENTIALS:-}"
  printf '\nexport DOMAIN_NAME ARBITER_LABEL PROJECT_NAME DOMAIN_DESCRIPTION\n'
} > "$TMPOUT"

if ! bash -n "$TMPOUT" 2>/dev/null; then
  say ""
  say "REFUSED: the generated pack is not valid shell. This is almost always an"
  say "answer containing a stray quote. Your existing pack was NOT touched."
  say "The bad draft is at: $TMPOUT"
  exit 2
fi

if [ "$PRINT_ONLY" = "1" ]; then
  cat "$TMPOUT"
  rm -f "$TMPOUT"
  exit 0
fi

if [ -f "$OUT" ]; then
  BAK="$OUT.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$OUT" "$BAK" 2>/dev/null && say "" && say "Backed up previous pack to $BAK"
fi
mkdir -p "$(dirname "$OUT")" 2>/dev/null
cp "$TMPOUT" "$OUT" || die "cannot write $OUT"
rm -f "$TMPOUT"
chmod 644 "$OUT" 2>/dev/null || true

rule
say "Wrote $OUT"
rule
say ""
say "The pack is written, but NOTHING HAS PICKED IT UP YET. The doctrine docs,"
say "the agent definitions and settings.json all carry brace placeholders"
say "that are filled from this file at install time. Run the substitution step:"
say ""
say "    ./install.sh --target . --substitute-only"
say ""
say "(or a full ./install.sh --target . — it is idempotent and will not destroy"
say "project content). Then confirm the walls are real:"
say ""
say "    grep -rn \"[{][{]\" .claude/agents .context 2>/dev/null | head"
say ""
say "Zero hits means every marker was filled. Hits mean a marker in a doc had no"
say "value in this pack — that is the one failure mode worth checking by hand,"
say "because a placeholder that survives into an agent definition reads to the"
say "model as literal text and quietly teaches it nothing."
exit 0
