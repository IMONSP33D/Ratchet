#!/usr/bin/env bash
# =============================================================================
# install.sh — deploy the RATCHET harness into a target repository.
#
# Ratchet is a gated autonomous-delivery harness for Claude Code: the run moves
# forward or it stops, and it never quietly slides back. This script is the
# thing a human runs once per repo. Everything after it is the agent's job.
#
# THE PROMISE THIS SCRIPT MAKES, AND THE ONE IT IS DESIGNED AROUND:
#   IT WILL NOT DAMAGE AN EXISTING PROJECT.
#   - An existing .claude/settings.json is MERGED, never overwritten, and is
#     backed up first.
#   - An existing CLAUDE.md is never clobbered; we write CLAUDE.ratchet.md and
#     tell you.
#   - Human-owned documents (.context/**, docs/**, .agent-development/**) are
#     written only when ABSENT. Harness-owned files (.claude/hooks/**,
#     .claude/agents/**) are replaced on upgrade, which is what "upgrade" means.
#   - --dry-run prints every action and performs none of them.
#   - Re-running is an upgrade, not a reinstall. It is idempotent.
#
# Usage:
#   ./install.sh --target ../my-repo --stack python-pytest --project-name "My Repo"
#   ./install.sh --dry-run --target ../my-repo
#   ./install.sh --target ../my-repo --substitute-only     # re-fill {{MARKERS}}
#   ./install.sh --target ../my-repo --uninstall
#
# Options:
#   --target <dir>            repo to install into            (default: cwd)
#   --stack <name>            python-pytest | node-jest | generic  (default: auto-detect)
#   --project-name <name>     human label                     (default: repo dir name)
#   --domain none|interactive run the domain interview?       (default: none)
#   --escalation-mode light|strict                            (default: light)
#   --base-branch <name>      the protected branch            (default: detected, else main)
#   --dry-run                 print every action, do nothing
#   --force                   proceed despite a dirty worktree
#   --substitute-only         only re-run {{MARKER}} substitution
#   --uninstall               reverse the install, restoring backups
#   --no-verify               skip running test_hooks.py at the end
#   --quiet | -q              errors and the final summary only
#   --no-color                never emit colour (same as NO_COLOR=1)
#   --ascii                   plain ASCII frames; no box-drawing characters
#   -h | --help
#
# Presentation is also controlled by the environment: NO_COLOR disables colour,
# RATCHET_ASCII disables box-drawing, and colour is suppressed entirely when
# stdout is not a terminal or TERM=dumb, so a redirected log stays clean.
#
# Exit codes:
#   0  installed / upgraded / uninstalled / dry-run completed
#   1  install completed but VERIFICATION FAILED (read the report)
#   2  refused before changing anything (host check, bad target, bad args)
# =============================================================================
set -uo pipefail
# NOT set -e. A failed optional step must be REPORTED, not silently abort a
# half-finished install. Every step that matters checks its own exit status.

RT_INSTALLER_VERSION="1.2.2"
# Install verification tier: quick (default, ~25s) | full (~95s) | smoke (~1s) | none.
# Quick is every security wall and meta-invariant. Full is the whole suite and is
# what you run once, and after any control-layer change.
VERIFY_TIER="${RATCHET_VERIFY_TIER:-quick}"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  printf 'install: cannot resolve my own directory\n' >&2; exit 2; }
HARNESS_DIR="$SRC_DIR/harness"

# ----------------------------------------------------------------- output ---
# PRESENTATION LAYER. Nothing below decides anything -- it only draws. The
# rules it obeys, because an installer whose chrome breaks the install is far
# worse than an ugly installer:
#   * safe under `set -u`: every read is defaulted, no unset variable is touched
#   * no external dependency: no figlet, no tput requirement (tput is consulted
#     only if it happens to exist, and only for the terminal width)
#   * not one escape byte reaches a redirected log: colour requires a TTY
#   * ASCII whenever UTF-8 is not known to be safe -- a mangled box border in
#     an install transcript is a support ticket
#   * width-aware: 80 by default, clamped to [40,100], never overflows a border
#
# Honoured, in this order: --ascii / RATCHET_ASCII, NO_COLOR, TERM=dumb, "am I
# even a terminal", then the locale.

RT_QUIET=0
RT_ASCII=0
RT_TTY=0
RT_COLOR=0
RT_W=80
RT_PHASE_TOTAL=7
RT_SPIN_PID=""
RT_SPIN_DELAY="0.12"
RT_SPIN_LABEL=""
RT_SPIN=('|' '/' '-' '\')
RT_AFTER_HEAD=0     # suppresses the blank line a step header would otherwise
                    # add immediately under a phase header

# Repeat a (possibly multi-byte) unit N times. Deliberately does not MEASURE
# anything: the caller knows how many columns it asked for, and counting bytes
# in a UTF-8 box character under a C locale is exactly how borders end up
# ragged. Non-numeric or negative counts render as nothing rather than erroring.
rt_rep() {
  local u="${1:-}" n="${2:-0}" out="" i=0
  case "$n" in (*[!0-9]*|"") n=0 ;; esac
  while [ "$i" -lt "$n" ]; do out="$out$u"; i=$((i+1)); done
  printf '%s' "$out"
}
rt_sp() { rt_rep ' ' "${1:-0}"; }

# Fit an ASCII string into exactly N columns: truncated with an ellipsis when
# too long, space-padded when short. Every string this is called with is a path
# or a label, so a byte count is a column count.
rt_fit() {
  local t="${1:-}" w="${2:-0}" n
  case "$w" in (*[!0-9]*|"") w=0 ;; esac
  n=${#t}
  if [ "$n" -gt "$w" ]; then
    if [ "$w" -gt 4 ]; then printf '%s...' "${t:0:$((w-3))}"
    else printf '%s' "${t:0:$w}"; fi
  else
    printf '%s%s' "$t" "$(rt_sp $((w-n)))"
  fi
}

# Truncate (never pad) so a header title cannot push a border past the width.
rt_clip() {
  local t="${1:-}" w="${2:-0}"
  case "$w" in (*[!0-9]*|"") w=0 ;; esac
  if [ "${#t}" -gt "$w" ]; then
    if [ "$w" -gt 4 ]; then printf '%s...' "${t:0:$((w-3))}"
    else printf '%s' "${t:0:$w}"; fi
  else
    printf '%s' "$t"
  fi
}

# Is it safe to emit box-drawing characters? Only when we are reasonably sure
# the receiving terminal decodes UTF-8. A wrong guess here produces the classic
# "â??" install log, so every uncertain case falls back to ASCII.
rt_unicode_ok() {
  [ "$RT_ASCII" = "1" ] && return 1
  [ -n "${RATCHET_ASCII:-}" ] && return 1
  case "${TERM:-}" in ""|dumb) return 1 ;; esac
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) return 0 ;;
  esac
  # A Windows console -- Git-Bash, MSYS, Cygwin -- is safe only on code page
  # 65001. The legacy pages mangle every byte above 0x7f, and that is the one
  # environment where this failure is common rather than theoretical.
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      case "$(chcp.com 2>/dev/null | tr -d '\r')" in *65001*) return 0 ;; esac
      return 1 ;;
  esac
  # No locale at all is normal in containers and CI, where the terminal is
  # UTF-8 regardless. Nothing this script MEASURES is non-ASCII, so a
  # byte-counting locale cannot misalign a column; only the glyphs are at risk.
  return 0
}

# Recomputed after argument parsing so --ascii / --no-color / --quiet apply.
rt_init_style() {
  local w=""

  RT_TTY=0
  [ -t 1 ] && RT_TTY=1

  # --- width ---------------------------------------------------------------
  # Redirected output gets a fixed 80 so a log is byte-identical wherever it
  # was produced.
  if [ "$RT_TTY" = "1" ]; then
    w="${COLUMNS:-}"
    if [ -z "$w" ] && command -v tput >/dev/null 2>&1; then
      w="$(tput cols 2>/dev/null || true)"
    fi
  fi
  case "$w" in (*[!0-9]*|"") w=80 ;; esac
  [ "$w" -lt 40 ]  && w=80
  [ "$w" -gt 100 ] && w=100
  RT_W="$w"

  # --- colour --------------------------------------------------------------
  RT_COLOR=0
  if [ "$RT_TTY" = "1" ] && [ -z "${NO_COLOR:-}" ]; then
    case "${TERM:-}" in
      ""|dumb) RT_COLOR=0 ;;
      *)
        case "${COLORTERM:-}|${TERM:-}" in
          truecolor*|24bit*|*256color*|*direct*) RT_COLOR=256 ;;
          *) RT_COLOR=16 ;;
        esac ;;
    esac
  fi

  if [ "$RT_COLOR" = "256" ]; then
    C_B=$'\033[1m';           C_0=$'\033[0m'
    C_R=$'\033[38;5;203m';    C_Y=$'\033[38;5;214m'
    C_G=$'\033[38;5;78m';     C_ACC=$'\033[38;5;38m'
    C_DIM=$'\033[38;5;243m';  C_TTL=$'\033[1;38;5;231m'
  elif [ "$RT_COLOR" = "16" ]; then
    C_B=$'\033[1m';           C_0=$'\033[0m'
    C_R=$'\033[31m';          C_Y=$'\033[33m'
    C_G=$'\033[32m';          C_ACC=$'\033[36m'
    C_DIM=$'\033[2m';         C_TTL=$'\033[1;37m'
  else
    C_B=""; C_0=""; C_R=""; C_Y=""; C_G=""; C_ACC=""; C_DIM=""; C_TTL=""
  fi

  # --- glyphs --------------------------------------------------------------
  if rt_unicode_ok; then
    G_OK=$'\xe2\x9c\x94'; G_WARN="!"; G_ERR=$'\xe2\x9c\x98'
    G_INFO=$'\xc2\xb7';   G_DRY=$'\xe2\x97\xa6'; G_SUB=$'\xe2\x96\xaa'
    B_H=$'\xe2\x94\x80';  B_V=$'\xe2\x94\x82'
    B_TL=$'\xe2\x94\x8c'; B_TR=$'\xe2\x94\x90'
    B_BL=$'\xe2\x94\x94'; B_BR=$'\xe2\x94\x98'
    D_H=$'\xe2\x95\x90';  D_V=$'\xe2\x95\x91'
    D_TL=$'\xe2\x95\x94'; D_TR=$'\xe2\x95\x97'
    D_BL=$'\xe2\x95\x9a'; D_BR=$'\xe2\x95\x9d'
    R_H=$'\xe2\x94\x81'
    LEAD=$'\xc2\xb7'
    BAR_F=$'\xe2\x96\xb0'; BAR_E=$'\xe2\x96\xb1'
    RT_SPIN=($'\xe2\xa0\x8b' $'\xe2\xa0\x99' $'\xe2\xa0\xb9' $'\xe2\xa0\xb8' \
             $'\xe2\xa0\xbc' $'\xe2\xa0\xb4' $'\xe2\xa0\xa6' $'\xe2\xa0\xa7' \
             $'\xe2\xa0\x87' $'\xe2\xa0\x8f')
  else
    G_OK="+"; G_WARN="!"; G_ERR="x"; G_INFO="."; G_DRY="o"; G_SUB="*"
    B_H="-"; B_V="|"; B_TL="+"; B_TR="+"; B_BL="+"; B_BR="+"
    D_H="="; D_V="|"; D_TL="+"; D_TR="+"; D_BL="+"; D_BR="+"
    R_H="="
    LEAD="."
    BAR_F="#"; BAR_E="-"
    RT_SPIN=('|' '/' '-' '\')
  fi

  # A spinner that cannot sleep for a fraction of a second would burn a core
  # for the whole test suite, so the capability is probed once, cheaply.
  if [ "$RT_TTY" = "1" ] && [ -z "$RT_SPIN_PID" ]; then
    if sleep 0.01 >/dev/null 2>&1; then RT_SPIN_DELAY="0.12"; else RT_SPIN_DELAY="1"; fi
  fi
}

rt_init_style

WARNINGS=0
MISSING_FILES=""

# --- the two-column status line ---------------------------------------------
# label ..................... status, right-flush, aligned whatever the label
# length is. When a label is too long for a leader (the wordy host-check
# messages are paragraphs, not labels) the line degrades to glyph + text rather
# than wrapping mid-word or pushing the status off the edge.
rt_status() {
  local col="${1:-}" gl="${2:-}" st="${3:-}"; shift 3
  local msg="$*" avail lead
  avail=$(( RT_W - 11 ))
  if [ -n "$st" ] && [ "${#msg}" -le $(( avail - 3 )) ]; then
    lead=$(( avail - ${#msg} ))
    printf '  %s%s%s  %s %s%s%s %s%4s%s\n' \
      "$col" "$gl" "$C_0" "$msg" \
      "$C_DIM" "$(rt_rep "$LEAD" "$lead")" "$C_0" \
      "$col" "$st" "$C_0"
  else
    printf '  %s%s%s  %s\n' "$col" "$gl" "$C_0" "$msg"
  fi
  RT_AFTER_HEAD=0
}

say()  { printf '%s\n' "$*"; }
raw()  { printf '%s\n' "$*"; }
ok()   { [ "$RT_QUIET" = "1" ] && return 0; rt_status "$C_G"   "$G_OK"   "ok"   "$*"; }
info() { [ "$RT_QUIET" = "1" ] && return 0; rt_status "$C_DIM" "$G_INFO" ""     "$*"; }
dry()  { [ "$RT_QUIET" = "1" ] && return 0; rt_status "$C_Y"   "$G_DRY"  "dry"  "$*"; }
warn() { WARNINGS=$((WARNINGS+1)); rt_status "$C_Y" "$G_WARN" "warn" "$*"; }
err()  { rt_status "$C_R" "$G_ERR" "FAIL" "$*" >&2; }
pass() { rt_status "$C_G" "$G_OK" "PASS" "$*"; }

# --- rules, headers, boxes ---------------------------------------------------
rt_rule() { # rt_rule [colour]
  printf '%s%s%s\n' "${1:-$C_DIM}" "$(rt_rep "$B_H" "$RT_W")" "$C_0"
}

# A numbered phase header: the reader always knows where they are and how much
# is left. The bar is dropped on narrow terminals rather than wrapped.
rt_phase() {
  [ "$RT_QUIET" = "1" ] && return 0
  local n="${1:-0}"; shift
  local title="$*" tag fill barw=12 barblock=0 filled cap
  tag="[$n/$RT_PHASE_TOTAL]"
  [ "$RT_W" -ge 66 ] && barblock=$(( barw + 1 ))
  cap=$(( RT_W - 7 - ${#tag} - barblock ))
  [ "$cap" -lt 8 ] && cap=8
  title="$(rt_clip "$title" "$cap")"
  fill=$(( RT_W - 5 - ${#tag} - ${#title} - barblock ))
  [ "$fill" -lt 2 ] && { barblock=0; fill=$(( RT_W - 5 - ${#tag} - ${#title} )); }
  [ "$fill" -lt 2 ] && fill=2
  printf '\n%s%s%s %s%s%s %s%s%s %s%s%s' \
    "$C_DIM" "$(rt_rep "$R_H" 2)" "$C_0" \
    "$C_ACC" "$tag" "$C_0" \
    "$C_TTL" "$title" "$C_0" \
    "$C_DIM" "$(rt_rep "$R_H" "$fill")" "$C_0"
  if [ "$barblock" -gt 0 ]; then
    filled=$(( n * barw / RT_PHASE_TOTAL ))
    [ "$filled" -gt "$barw" ] && filled="$barw"
    printf ' %s%s%s%s%s' \
      "$C_ACC" "$(rt_rep "$BAR_F" "$filled")" \
      "$C_DIM" "$(rt_rep "$BAR_E" $(( barw - filled )))" "$C_0"
  fi
  printf '\n\n'
  RT_AFTER_HEAD=1
}

# An unnumbered full-width header, for the paths that are not the seven-phase
# install: uninstall, --substitute-only, and the closing blocks.
rt_head() {
  local title="$*" fill
  title="$(rt_clip "$title" $(( RT_W - 6 )))"
  fill=$(( RT_W - 4 - ${#title} ))
  [ "$fill" -lt 2 ] && fill=2
  printf '\n%s%s%s %s%s%s %s%s%s\n\n' \
    "$C_DIM" "$(rt_rep "$R_H" 2)" "$C_0" \
    "$C_TTL" "$title" "$C_0" \
    "$C_DIM" "$(rt_rep "$R_H" "$fill")" "$C_0"
  RT_AFTER_HEAD=1
}

# A step inside a phase. Its own blank line is dropped when it lands directly
# under a phase header, so the two never stack into a gap.
rt_sub() {
  [ "$RT_QUIET" = "1" ] && return 0
  [ "$RT_AFTER_HEAD" = "1" ] || printf '\n'
  printf '  %s%s%s  %s%s%s\n' "$C_ACC" "$G_SUB" "$C_0" "$C_B" "$*" "$C_0"
  RT_AFTER_HEAD=1
}
head1() { rt_sub "$*"; }

# --- boxes -------------------------------------------------------------------
# Every box line is built from a known column count, never from a measurement
# of a multi-byte string, so a border cannot come out ragged.
rt_box_top() { # rt_box_top <style: light|double> [title]
  local st="${1:-light}" title="${2:-}" h v tl tr fill
  if [ "$st" = "double" ]; then h="$D_H"; tl="$D_TL"; tr="$D_TR"
  else h="$B_H"; tl="$B_TL"; tr="$B_TR"; fi
  if [ -n "$title" ]; then
    title="$(rt_clip "$title" $(( RT_W - 7 )))"
    fill=$(( RT_W - 5 - ${#title} ))
    [ "$fill" -lt 1 ] && fill=1
    printf '%s%s%s %s%s%s %s%s%s%s\n' \
      "$C_ACC" "$tl$h" "$C_0" "$C_TTL" "$title" "$C_0" \
      "$C_ACC" "$(rt_rep "$h" "$fill")" "$tr" "$C_0"
  else
    printf '%s%s%s%s%s\n' "$C_ACC" "$tl" "$(rt_rep "$h" $(( RT_W - 2 )))" "$tr" "$C_0"
  fi
}
rt_box_bottom() {
  local st="${1:-light}" h bl br
  if [ "$st" = "double" ]; then h="$D_H"; bl="$D_BL"; br="$D_BR"
  else h="$B_H"; bl="$B_BL"; br="$B_BR"; fi
  printf '%s%s%s%s%s\n' "$C_ACC" "$bl" "$(rt_rep "$h" $(( RT_W - 2 )))" "$br" "$C_0"
}
# rt_box_line <style> <plain-text>  -- padded to the border, truncated if long
rt_box_line() {
  local st="${1:-light}" text="${2:-}" col="${3:-}" v
  if [ "$st" = "double" ]; then v="$D_V"; else v="$B_V"; fi
  printf '%s%s%s %s%s%s %s%s%s\n' \
    "$C_ACC" "$v" "$C_0" \
    "$col" "$(rt_fit "$text" $(( RT_W - 4 )))" "$C_0" \
    "$C_ACC" "$v" "$C_0"
}
# rt_box_kv <style> <key> <value> [value-colour] -- the summary table's rows
rt_box_kv() {
  local st="${1:-light}" k="${2:-}" val="${3:-}" vc="${4:-}" v kw=18
  if [ "$st" = "double" ]; then v="$D_V"; else v="$B_V"; fi
  printf '%s%s%s   %s%s%s  %s%s%s %s%s%s\n' \
    "$C_ACC" "$v" "$C_0" \
    "$C_DIM" "$(rt_fit "$k" "$kw")" "$C_0" \
    "${vc:-$C_B}" "$(rt_fit "$val" $(( RT_W - kw - 8 )))" "$C_0" \
    "$C_ACC" "$v" "$C_0"
}

rt_banner() {
  [ "$RT_QUIET" = "1" ] && return 0
  local plain pad
  printf '\n'
  rt_box_top double
  rt_box_line double ""
  # The one line drawn by hand rather than by rt_box_line, because it carries
  # two colours. The padding is still derived from an ASCII twin of the line,
  # so it cannot disagree with the border.
  plain="  R A T C H E T   v$RT_INSTALLER_VERSION"
  pad=$(( RT_W - 4 - ${#plain} ))
  [ "$pad" -lt 0 ] && pad=0
  printf '%s%s%s %s  R A T C H E T%s   %s%s%s%s %s%s%s\n' \
    "$C_ACC" "$D_V" "$C_0" \
    "$C_TTL" "$C_0" \
    "$C_ACC" "v$RT_INSTALLER_VERSION" "$C_0" "$(rt_sp "$pad")" \
    "$C_ACC" "$D_V" "$C_0"
  rt_box_line double "  the run moves forward or it stops; it never quietly slides back" "$C_DIM"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    rt_box_line double ""
    rt_box_line double "  DRY RUN -- every action is printed, and nothing is written" "$C_Y"
  fi
  rt_box_line double ""
  rt_box_bottom double
}

# --- spinner -----------------------------------------------------------------
# Two steps in this installer are slow enough (the hook suite, then the
# postcondition baseline that re-runs it) that silence is indistinguishable
# from a hang. On a TTY that is a spinner; anywhere else it is one static line,
# because a carriage-return animation in a redirected log is unreadable noise.
rt_spin_start() {
  RT_SPIN_LABEL="$*"
  [ "$RT_QUIET" = "1" ] && return 0
  if [ "$RT_TTY" != "1" ]; then
    printf '  %s%s%s  %s ... working\n' "$C_DIM" "$G_INFO" "$C_0" "$RT_SPIN_LABEL"
    return 0
  fi
  (
    i=0
    while :; do
      printf '\r  %s%s%s  %s%s%s ' \
        "$C_ACC" "${RT_SPIN[$(( i % ${#RT_SPIN[@]} ))]}" "$C_0" \
        "$C_DIM" "$RT_SPIN_LABEL" "$C_0"
      i=$(( i + 1 ))
      sleep "$RT_SPIN_DELAY" 2>/dev/null || sleep 1
    done
  ) &
  RT_SPIN_PID=$!
}
rt_spin_kill() {
  [ -n "$RT_SPIN_PID" ] || return 0
  kill "$RT_SPIN_PID" >/dev/null 2>&1
  wait "$RT_SPIN_PID" >/dev/null 2>&1
  RT_SPIN_PID=""
  printf '\r%s\r' "$(rt_sp "$RT_W")"
}
# rt_spin_stop <ok|warn|fail> <message> -- clears the animation, then reports
rt_spin_stop() {
  local kind="${1:-ok}"; shift
  rt_spin_kill
  [ "$RT_QUIET" = "1" ] && return 0
  case "$kind" in
    ok)   ok "$*" ;;
    none) : ;;
    *)    info "$*" ;;
  esac
}

die()  {
  local msg="$*" first rest
  rt_spin_kill
  first="$(printf '%s\n' "$msg" | head -1)"
  rest="$(printf '%s\n' "$msg" | tail -n +2)"
  {
    printf '\n  %s%s%s  %sinstall refused:%s %s\n' \
      "$C_R" "$G_ERR" "$C_0" "$C_R$C_B" "$C_0" "$first"
    if [ -n "$rest" ]; then
      printf '%s\n' "$rest" | while IFS= read -r l; do printf '   %s\n' "$l"; done
    fi
    printf '\n'
  } >&2
  exit 2
}

# ------------------------------------------------------------------ args ----
TARGET=""
STACK=""
PROJECT_NAME=""
DOMAIN_MODE="none"
ESCALATION_MODE="light"
BASE_BRANCH=""
DRY_RUN=0
FORCE=0
UNINSTALL=0
SUBST_ONLY=0
RUN_VERIFY=1

# Print the header comment block and stop at the first non-comment line, so the
# help text can never drift out of sync with the header by a line count.
usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)          shift; [ $# -gt 0 ] || die "--target needs a directory"; TARGET="$1" ;;
    --target=*)        TARGET="${1#--target=}" ;;
    --stack)           shift; [ $# -gt 0 ] || die "--stack needs a name"; STACK="$1" ;;
    --stack=*)         STACK="${1#--stack=}" ;;
    --project-name)    shift; [ $# -gt 0 ] || die "--project-name needs a value"; PROJECT_NAME="$1" ;;
    --project-name=*)  PROJECT_NAME="${1#--project-name=}" ;;
    --domain)          shift; [ $# -gt 0 ] || die "--domain needs none|interactive"; DOMAIN_MODE="$1" ;;
    --domain=*)        DOMAIN_MODE="${1#--domain=}" ;;
    --escalation-mode) shift; [ $# -gt 0 ] || die "--escalation-mode needs light|strict"; ESCALATION_MODE="$1" ;;
    --escalation-mode=*) ESCALATION_MODE="${1#--escalation-mode=}" ;;
    --base-branch)     shift; [ $# -gt 0 ] || die "--base-branch needs a name"; BASE_BRANCH="$1" ;;
    --base-branch=*)   BASE_BRANCH="${1#--base-branch=}" ;;
    --dry-run|-n)      DRY_RUN=1 ;;
    --force)           FORCE=1 ;;
    --uninstall)       UNINSTALL=1 ;;
    --substitute-only) SUBST_ONLY=1 ;;
    --no-verify)       RUN_VERIFY=0 ;;
    --verify)  shift; VERIFY_TIER="${1:-quick}" ;;
    --verify=*) VERIFY_TIER="${1#*=}" ;;
    --quiet|-q)        RT_QUIET=1 ;;
    --no-color|--no-colour) NO_COLOR=1; export NO_COLOR ;;
    --ascii)           RT_ASCII=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$DOMAIN_MODE" in
  none|interactive) ;;
  *) die "--domain must be 'none' or 'interactive' (got: $DOMAIN_MODE)" ;;
esac
case "$ESCALATION_MODE" in
  light|strict) ;;
  *) die "--escalation-mode must be 'light' or 'strict' (got: $ESCALATION_MODE)" ;;
esac

# The style was initialised once already so that a `die` during argument
# parsing is still legible; recompute it now that --quiet/--ascii/--no-color
# have been seen, then draw the header.
rt_init_style
rt_banner

# ============================================================================
# SECTION 1 — HOST CHECKS. These run FIRST and they run before anything on
# disk is touched. A harness whose gates cannot execute is worse than no
# harness: it looks like it is protecting you and it is not.
# ============================================================================
rt_phase 1 "Host checks"

HOST_FATAL=0

# --- bash 4+ ---------------------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ]; then
  err "cannot determine the bash version. Run this with bash, not sh:  bash install.sh ..."
  HOST_FATAL=1
elif [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  err "bash ${BASH_VERSION} is too old. Ratchet's hooks need bash 4 or newer."
  say "        macOS ships bash 3.2 for licensing reasons. Fix:"
  say "            brew install bash        # then re-run with: /opt/homebrew/bin/bash install.sh"
  HOST_FATAL=1
else
  ok "bash ${BASH_VERSION%%(*}"
fi

# --- git -------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  ok "git $(git --version 2>/dev/null | awk '{print $3}')"
else
  err "git not found. Ratchet's gates read the worktree on every hook firing."
  say "        Fix: install git and put it on PATH. https://git-scm.com/downloads"
  HOST_FATAL=1
fi

# --- jq (REQUIRED, and this is not negotiable) -----------------------------
# CONTRACT §3: every hook parses a JSON payload on stdin. Non-security fields
# may degrade to sed/grep, but a SECURITY decision made from a regex over JSON
# is a security decision made from a guess -- so absent jq, the guards BLOCK.
# A Ratchet install without jq is a repo where the agent cannot run any Bash
# command at all. We refuse here rather than let you discover that later.
if command -v jq >/dev/null 2>&1; then
  ok "jq $(jq --version 2>/dev/null)"
else
  err "jq not found. This is a HARD requirement, not a nicety."
  say "        Every Ratchet hook parses its payload as JSON. Security decisions"
  say "        made without a real JSON parser are guesses, so the guards fail"
  say "        CLOSED when jq is absent -- meaning every Bash tool call is blocked."
  say "        Installing without jq produces a repo the agent cannot work in."
  say ""
  say "        Fix:  Debian/Ubuntu   sudo apt-get install -y jq"
  say "              macOS           brew install jq"
  say "              Windows         winget install jqlang.jq   (or: choco install jq)"
  say "              Git-Bash        drop jq.exe into C:\\Program Files\\Git\\usr\\bin"
  HOST_FATAL=1
fi

# --- python3 (CONTRACT §4.1 probe, verbatim behaviour) ---------------------
# The Windows Store python stub is on PATH as "python3" and does nothing except
# open the Store. It exits non-zero or prints nothing, which is exactly what
# this probe tests for. Never trust `command -v python3` alone on Windows.
PY=""
probe_py() {
  local cand="$1" out=""
  # shellcheck disable=SC2086
  command -v ${cand%% *} >/dev/null 2>&1 || return 1
  out="$($cand -c "import sys;print(sys.version_info[0])" 2>/dev/null | tr -d ' \r\n')"
  [ "$out" = "3" ] || return 1
  return 0
}
for cand in "${RATCHET_PYTHON:-}" python3 python "py -3"; do
  [ -n "$cand" ] || continue
  if probe_py "$cand"; then PY="$cand"; break; fi
done
if [ -n "$PY" ]; then
  ok "python3 via '$PY' ($($PY -c 'import sys;print(sys.version.split()[0])' 2>/dev/null))"
else
  err "no working Python 3 found (probed \$RATCHET_PYTHON, python3, python, 'py -3')."
  say "        Four of Ratchet's gates are Python: check_done.py, check_narrative.py,"
  say "        proof_map.py, run_metrics.py. Without an interpreter the ship gate"
  say "        cannot evaluate the definition of done, and it fails closed."
  say ""
  say "        If you are on Windows and 'python3' DID appear to exist: that is the"
  say "        Microsoft Store stub. It is a placeholder that opens the Store and"
  say "        exits. Install real Python from python.org and tick 'Add to PATH',"
  say "        or turn the stub off in Settings > Apps > App execution aliases."
  HOST_FATAL=1
fi

# --- can PYTHON spawn a working bash? (the WSL relay trap) -----------------
# This script IS bash, so bash obviously works here. That proves nothing about
# what the Python side gets: test_hooks.py drives every hook by spawning bash,
# and it resolves that name independently. On Windows the first `bash` on PATH
# is usually C:\Windows\System32\bash.exe -- the WSL *relay* -- which dies with
# "execvpe(/bin/bash) failed" before the hook runs when no distro is installed.
#
# We hand Python OUR bash first, because we are running under one that works.
# Only if Python cannot run even that do we have a real problem.
if [ -n "$PY" ]; then
  SELF_BASH="${BASH:-}"
  [ -n "$SELF_BASH" ] || SELF_BASH="$(command -v bash 2>/dev/null || true)"

  # NOTE: $PY is deliberately UNQUOTED. It may be multi-word ("py -3"), and a
  # quoted expansion looks for a file literally named "py -3", silently yields
  # nothing, and makes a working host look broken. (It did exactly that.)
  PY_BASH="$(RATCHET_SELF_BASH="$SELF_BASH" $PY - <<'PYEOF' 2>/dev/null
import os, shutil, subprocess, sys

def works(c):
    if not c:
        return False
    try:
        r = subprocess.run([c, "-c", "printf ratchet-ok"],
                           capture_output=True, text=True, timeout=20)
    except Exception:
        return False
    return r.returncode == 0 and "ratchet-ok" in (r.stdout or "")

cands, seen = [], set()
def add(c):
    if c and c not in seen:
        seen.add(c); cands.append(c)

add(os.environ.get("RATCHET_BASH"))
add(os.environ.get("RATCHET_SELF_BASH"))     # the shell running the installer
if os.name == "nt":
    for root in (os.environ.get("ProgramFiles", r"C:\Program Files"),
                 os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                 os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs")):
        if root:
            for sub in (r"Git\bin\bash.exe", r"Git\usr\bin\bash.exe"):
                add(os.path.join(root, sub))
else:
    for c in ("/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"):
        add(c)
add(shutil.which("bash"))

for c in cands:
    if os.sep in c and not os.path.isfile(c):
        continue
    if works(c):
        print(c); break
PYEOF
)"

  if [ -n "$PY_BASH" ]; then
    ok "python can spawn bash ('$PY_BASH')"
    [ -n "${RATCHET_BASH:-}" ] || export RATCHET_BASH="$PY_BASH"
  else
    # Before blaming bash, check the far likelier cause: a Windows Python being
    # driven from a WSL shell. Those two live in different filesystems, so no
    # bash path can satisfy both and the harness cannot work that way at all.
    PY_WIN=0
    case "$($PY -c 'import sys;print(sys.platform)' 2>/dev/null)" in win32|cygwin) PY_WIN=1 ;; esac
    IN_WSL=0
    { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; } && IN_WSL=1

    if [ "$PY_WIN" = "1" ] && [ "$IN_WSL" = "1" ]; then
      err "You are in a WSL shell, but '$PY' is a WINDOWS Python."
      say "        These two do not share a filesystem. WSL sees /home/you/repo;"
      say "        Windows Python sees C:\\Users\\you\\repo. No single bash path can"
      say "        satisfy both, so the hooks would be handed paths that do not exist"
      say "        on the other side -- and every error would name a real file, which"
      say "        is the most confusing failure this harness can produce."
      say ""
      say "        Pick ONE world and stay in it:"
      say "          - all-WSL (recommended if you are already here):"
      say "                sudo apt install python3 git"
      say "                clone the repo INSIDE WSL (~/, not /mnt/c) and install there"
      say "          - all-Windows: run install.ps1 from PowerShell, or install.sh"
      say "                from Git-Bash, with python.org Python on PATH"
    else
      err "Python cannot spawn a working bash."
      say "        Every hook is a bash script and the suite drives them through Python,"
      say "        so this breaks the control layer in the most confusing way possible:"
      say "        the gates are fine, but every test fails with an exec error."
      say ""
      say "        Tried, in order: \$RATCHET_BASH, this shell's own bash ($SELF_BASH),"
      say "        the standard locations, then whatever 'bash' is on PATH."
      say "        On Windows this is usually C:\\Windows\\System32\\bash.exe (the WSL"
      say "        relay) shadowing Git-Bash, with no distro installed."
      say ""
      say "        Fix: install Git for Windows, or point us at a bash you trust:"
      say "            RATCHET_BASH=\"/usr/bin/bash\" ./install.sh ...   (WSL/Linux/macOS)"
      say "            set RATCHET_BASH=\"C:\\Program Files\\Git\\bin\\bash.exe\"  (Windows)"
    fi
    HOST_FATAL=1
  fi
fi

# --- gh (WARN: needed only for the ship flow) ------------------------------
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}') (authenticated)"
  else
    warn "gh is installed but not authenticated. The ship flow (open PR, merge) will"
    say "        fail at the last step of your first run. Fix now:  gh auth login"
  fi
else
  warn "gh (GitHub CLI) not found. Everything up to the Ship Prompt works without it,"
  say "        but the run ends by opening a PR and merging it, and both are gh."
  say "        Fix:  https://cli.github.com  then: gh auth login"
fi

# --- randomness for the escalation key -------------------------------------
if command -v openssl >/dev/null 2>&1; then
  ok "openssl (escalation key source)"
elif [ -r /dev/urandom ]; then
  ok "/dev/urandom (escalation key source)"
else
  warn "no openssl and no readable /dev/urandom. The escalation signing key cannot be"
  say "        generated automatically; you will have to create it by hand."
fi

# --- stack detection + stack tool checks (WARN only) -----------------------
detect_stack() {
  local t="$1"
  if [ -f "$t/pyproject.toml" ] || [ -f "$t/setup.py" ] || [ -f "$t/pytest.ini" ] \
     || [ -f "$t/tox.ini" ] || [ -f "$t/requirements.txt" ]; then
    echo "python-pytest"; return
  fi
  if [ -f "$t/package.json" ]; then echo "node-jest"; return; fi
  echo "generic"
}

stack_tools() {
  case "$1" in
    python-pytest) echo "python3 pytest" ;;
    node-jest)     echo "node npm" ;;
    *)             echo "" ;;
  esac
}

# ============================================================================
# SECTION 2 — TARGET VALIDATION
# ============================================================================
rt_phase 2 "Target"

[ -n "$TARGET" ] || TARGET="$PWD"
if [ ! -d "$TARGET" ]; then
  die "target directory does not exist: $TARGET"
fi
TARGET="$(cd "$TARGET" && pwd)" || die "cannot enter target: $TARGET"

# Refuse to install onto ourselves. The harness source tree is not a project.
if [ "$TARGET" = "$SRC_DIR" ]; then
  die "the target is the Ratchet source tree itself ($SRC_DIR).
  Ratchet installs INTO a project. Point --target at the repo you want gated:
      ./install.sh --target ../my-repo"
fi
case "$TARGET/" in
  "$HARNESS_DIR"/*) die "the target is inside the harness source tree ($HARNESS_DIR)." ;;
esac

ok "target: $TARGET"

# --- must be a git repo ----------------------------------------------------
if ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  die "$TARGET is not a git repository.
  Ratchet's gates are defined in terms of branches, diffs and a protected base
  branch; there is nothing coherent to install into a non-repo. Fix:
      git -C \"$TARGET\" init && git -C \"$TARGET\" commit --allow-empty -m 'init'"
fi
TARGET_ROOT="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$TARGET_ROOT" ] && [ "$TARGET_ROOT" != "$TARGET" ]; then
  warn "you pointed at a subdirectory; installing at the repo root instead: $TARGET_ROOT"
  TARGET="$TARGET_ROOT"
fi
ok "git repository confirmed"

# --- dirty worktree --------------------------------------------------------
# The check exists to protect uncommitted WORK, so it distinguishes the two
# kinds of dirty. A MODIFIED OR STAGED TRACKED FILE is work at risk: if the
# install goes wrong you want `git checkout .` to be a complete undo, and it
# only is when nothing tracked was already changed. UNTRACKED files are a
# different situation -- and they are the normal situation on every upgrade,
# because the previous install left .claude/hooks/ untracked. Refusing those
# would mean --force on every single upgrade, which trains you to pass --force
# always, which is how the check stops meaning anything.
MANIFEST_PROBE="$TARGET/.claude/.ratchet-install-manifest"
DIRTY_TRACKED="$(git -C "$TARGET" status --porcelain 2>/dev/null | grep -v '^??' | head -20)"
DIRTY_UNTRACKED="$(git -C "$TARGET" status --porcelain 2>/dev/null | grep -c '^??' 2>/dev/null)"
if [ -n "$DIRTY_TRACKED" ]; then
  if [ "$FORCE" = "1" ] || [ "$DRY_RUN" = "1" ] || [ "$SUBST_ONLY" = "1" ] || [ "$UNINSTALL" = "1" ]; then
    warn "tracked files are modified; continuing (--force/--dry-run/--substitute-only/--uninstall)."
  else
    printf '\n  %s%s%s  %sinstall refused:%s the target has modified or staged tracked files.\n\n' \
      "$C_R" "$G_ERR" "$C_0" "$C_R$C_B" "$C_0" >&2
    printf '%s\n' "$DIRTY_TRACKED" | sed 's/^/    /' >&2
    printf '\n  This matters more than usual here. The installer writes into .claude/,\n' >&2
    printf '  .context/ and .gitignore, and merges your settings.json. If any of that\n' >&2
    printf '  is wrong you will want "git checkout ." to be a complete undo -- and it\n' >&2
    printf '  only is if nothing tracked was already modified.\n\n' >&2
    printf '  Commit or stash, then re-run. Or --force if you know what you are doing.\n' >&2
    if [ -f "$MANIFEST_PROBE" ]; then
      printf '\n  Ratchet is already installed here, so if the list above is just\n' >&2
      printf '  .claude/settings.json and .gitignore, those are the PREVIOUS install\n' >&2
      printf '  and committing them is the right move:\n' >&2
      printf '      git -C "%s" add -A && git -C "%s" commit -m "chore: install Ratchet"\n\n' "$TARGET" "$TARGET" >&2
    else
      printf '\n' >&2
    fi
    exit 2
  fi
elif [ "${DIRTY_UNTRACKED:-0}" -gt 0 ] 2>/dev/null; then
  info "worktree has ${DIRTY_UNTRACKED} untracked path(s); no tracked file is modified, so"
  info "  'git checkout .' is still a complete undo of anything this installer changes."
else
  ok "worktree clean"
fi

# --- base branch -----------------------------------------------------------
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git -C "$TARGET" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$BASE_BRANCH" ] || BASE_BRANCH="$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$BASE_BRANCH" in ""|HEAD) BASE_BRANCH="main" ;; esac
fi
ok "base branch: $BASE_BRANCH  (this is the branch that must be protected)"

# --- project name / stack --------------------------------------------------
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$TARGET")"
if [ -z "$STACK" ]; then
  STACK="$(detect_stack "$TARGET")"
  ok "stack auto-detected: $STACK"
else
  case "$STACK" in
    python-pytest|node-jest|generic) ok "stack: $STACK" ;;
    *) die "--stack must be python-pytest, node-jest or generic (got: $STACK)" ;;
  esac
fi
for tool in $(stack_tools "$STACK"); do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "stack tool: $tool"
  else
    warn "stack tool '$tool' not found. The $STACK pack's commands will fail when a"
    say "        gate runs them. Gates that need a command they cannot run SKIP with a"
    say "        loud notice -- they do not silently pass -- so this is safe but noisy."
  fi
done

if [ "$HOST_FATAL" = "1" ]; then
  printf '\n' >&2
  rt_rule "$C_R" >&2
  printf '  %s%s%s  %sinstall refused:%s one or more required host tools are missing.\n' \
    "$C_R" "$G_ERR" "$C_0" "$C_R$C_B" "$C_0" >&2
  printf '  Nothing was written.\n\n' >&2
  printf '  Easiest fix -- the dependency installer reads the same checks and installs\n' >&2
  printf '  what is missing for your platform:\n\n' >&2
  printf '      ./ratchet-dependencies.sh --check      # report only, changes nothing\n' >&2
  printf '      ./ratchet-dependencies.sh              # install what is missing\n\n' >&2
  printf '  (Windows/PowerShell: .\\ratchet-dependencies.ps1 -Check)\n' >&2
  printf '  Then re-run this installer.\n' >&2
  printf '  Every one of them is a tool a SECURITY GATE needs, which is why this is\n' >&2
  printf '  a refusal and not a warning: a gate that cannot run has not passed.\n' >&2
  rt_rule "$C_R" >&2
  printf '\n' >&2
  exit 2
fi

# ============================================================================
# SECTION 3 — ACTION PRIMITIVES (all honour --dry-run)
# ============================================================================
MANIFEST="$TARGET/.claude/.ratchet-install-manifest"
MANIFEST_TMP=""
INSTALL_STATE="$TARGET/.claude/.ratchet-install.json"

act() { # act <description> ; then the command
  local desc="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then
    dry "$desc"
    return 0
  fi
  "$@"
}

record() { # record a manifest line so --uninstall can reverse it
  [ "$DRY_RUN" = "1" ] && return 0
  [ -n "$MANIFEST_TMP" ] || return 0
  printf '%s\n' "$*" >> "$MANIFEST_TMP"
}

mkdirp() { # mkdirp <relpath>
  local d="$TARGET/$1"
  if [ -d "$d" ]; then return 0; fi
  if [ "$DRY_RUN" = "1" ]; then dry "mkdir $1"; return 0; fi
  mkdir -p "$d" || { err "cannot create $1"; return 1; }
  record "D $1"
}

# copy_file <src-abs> <rel-dest> <mode: replace|if-absent>
copy_file() {
  local src="$1" rel="$2" mode="${3:-replace}" dst="$TARGET/$2"
  if [ ! -f "$src" ]; then
    MISSING_FILES="${MISSING_FILES}${rel}
"
    return 1
  fi
  if [ -f "$dst" ] && [ "$mode" = "if-absent" ]; then
    info "kept existing $rel (yours; not overwritten)"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    dry "write $rel"
    return 0
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  # Write LF endings. Hooks are bash; a CRLF shebang line makes the kernel look
  # for an interpreter literally named "bash\r", and the error it produces
  # ("bad interpreter") names a file that appears to exist. Strip \r on copy.
  if LC_ALL=C tr -d '\r' < "$src" > "$dst.rt-tmp" 2>/dev/null; then
    mv -f "$dst.rt-tmp" "$dst" 2>/dev/null || { cp -f "$dst.rt-tmp" "$dst"; rm -f "$dst.rt-tmp"; }
  else
    rm -f "$dst.rt-tmp" 2>/dev/null
    cp -f "$src" "$dst" || { err "cannot write $rel"; return 1; }
  fi
  record "F $rel"
  return 0
}

# write_file <rel-dest> <mode> ; content on stdin
write_file() {
  local rel="$1" mode="${2:-replace}" dst="$TARGET/$1"
  if [ -f "$dst" ] && [ "$mode" = "if-absent" ]; then
    cat >/dev/null
    info "kept existing $rel (yours; not overwritten)"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    cat >/dev/null
    dry "write $rel"
    return 0
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  cat > "$dst" || { err "cannot write $rel"; return 1; }
  record "F $rel"
  return 0
}

# ============================================================================
# SECTION 4 — UNINSTALL
# ============================================================================
if [ "$UNINSTALL" = "1" ]; then
  rt_head "Uninstall"
  if [ ! -f "$MANIFEST" ]; then
    die "no install manifest at .claude/.ratchet-install-manifest.
  Either Ratchet was never installed here, or it was installed by hand. This
  script will not guess which files are yours -- deleting a project's .claude/
  on a guess is exactly the damage it exists to avoid. Remove by hand:
      .claude/hooks/  .claude/agents/  .claude/settings.json
  and restore any .claude/settings.json.bak-* you find."
  fi
  RESTORED=""
  # Restore backups FIRST: if anything below fails, the settings are already back.
  #
  # ONE RESTORE PER ORIGINAL, AND IT IS THE OLDEST BACKUP. Every install takes
  # a backup, so after three upgrades there are three .bak files for
  # settings.json -- and two of them are Ratchet-merged documents, not the
  # user's original. Restoring them in manifest order would "uninstall" the
  # harness by handing back a file that still contains the harness. The
  # manifest is sorted and backup names are UTC timestamps, so the first B line
  # for a given original is the oldest, which is the only one that predates
  # Ratchet.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "B "*)
        set -- $line
        bak="$2"; orig="$3"
        case " $RESTORED " in *" $orig "*) continue ;; esac
        if [ "$bak" = "-" ]; then
          # There was no such file before Ratchet. Removing it IS the restore.
          [ -f "$TARGET/$orig" ] && act "remove $orig (did not exist before install)" rm -f "$TARGET/$orig"
          ok "removed $orig (this project had none before Ratchet)"
          RESTORED="$RESTORED $orig"
          continue
        fi
        if [ -f "$TARGET/$bak" ]; then
          act "restore $orig from $bak" cp -f "$TARGET/$bak" "$TARGET/$orig" \
            && { ok "restored $orig from $bak (the pre-Ratchet original)"; RESTORED="$RESTORED $orig"; }
        else
          warn "backup $bak is gone; cannot restore $orig"
        fi
        ;;
    esac
  done < "$MANIFEST"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "F "*)
        rel="${line#F }"
        case " $RESTORED " in *" $rel "*) continue ;; esac
        [ -f "$TARGET/$rel" ] && act "remove $rel" rm -f "$TARGET/$rel"
        ;;
    esac
  done < "$MANIFEST"

  # Remove now-empty harness dirs, deepest first. Never force-remove a dir with
  # content in it: content in .pipeline/ or docs/evidence/ is the project's work.
  for d in .claude/hooks/stack .claude/hooks .claude/agents .claude; do
    if [ -d "$TARGET/$d" ]; then
      act "rmdir $d (only if empty)" rmdir "$TARGET/$d" 2>/dev/null && ok "removed empty $d"
    fi
  done
  act "remove install manifest" rm -f "$MANIFEST" "$INSTALL_STATE"

  rt_head "Uninstall complete"
  say "  LEFT IN PLACE, deliberately -- this is your project's work, not the harness:"
  say "    .context/        your SPEC, MILESTONES, DECISIONS and their archive"
  say "    .agent-development/  the learning loop: run retros, lessons, pending actions"
  say "    .pipeline/       the last run's scratch, findings ledger and checkpoints"
  say "    docs/evidence/   WIN-row proof and probe transcripts"
  say "    secrets/         the escalation signing key (delete it yourself if you mean to)"
  say "    .claude/hooks/domain.config.sh   your domain pack: the walls you configured"
  say "    .claude/settings.json.bak-*      every backup this installer ever took"
  say ""
  say "  Delete any of those by hand if you want them gone. The installer will not,"
  say "  because none of it was written by the installer."
  exit 0
fi

# ============================================================================
# SECTION 5 — INSTALL
# ============================================================================
rt_phase 3 "Installing the harness"

if [ ! -d "$HARNESS_DIR" ]; then
  die "harness source tree not found at $HARNESS_DIR.
  install.sh expects to sit next to a 'harness/' directory containing
  .claude/, .context/ and the rest. Are you running it from an incomplete
  checkout?"
fi

if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$TARGET/.claude" || die "cannot create $TARGET/.claude"
  MANIFEST_TMP="$TARGET/.claude/.ratchet-install-manifest.new"
  : > "$MANIFEST_TMP" || die "cannot write the install manifest"
  printf '# Ratchet install manifest -- written by install.sh %s at %s\n' \
    "$RT_INSTALLER_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MANIFEST_TMP"
  printf '# Read by: install.sh --uninstall. Lines: "F <rel>" file, "D <rel>" dir,\n' >> "$MANIFEST_TMP"
  printf '# "B <backup-rel> <original-rel>" a backup that uninstall restores.\n' >> "$MANIFEST_TMP"
  # Preserve backup records from any previous install so an upgrade->uninstall
  # still restores the ORIGINAL settings.json, not the one we generated.
  if [ -f "$MANIFEST" ]; then
    grep '^B ' "$MANIFEST" >> "$MANIFEST_TMP" 2>/dev/null
  fi
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"

# ---------------------------------------------------------------- 5.1 dirs --
rt_sub "Scaffolding the four-directory partition"
for d in \
  .claude/hooks/stack .claude/agents .claude/doctrine \
  .context/archive/decisions \
  .pipeline/checkpoints .pipeline/escalations .pipeline/dispatch .pipeline/archive \
  .agent-development/runs .agent-development/consolidated \
  .agent-development/metrics .agent-development/proposals \
  docs/evidence \
  secrets
do
  mkdirp "$d"
done
ok ".claude/ (control layer, agent-unwritable: hooks, agents, doctrine)"
ok ".context/ (your three contracts: SPEC, MILESTONES, DECISIONS)"
ok ".pipeline/ (run scratch, mostly gitignored)"
ok ".agent-development/ (learning loop, tracked, never pruned)"
ok "docs/evidence/, secrets/"

# secrets/ must be 0700 where the OS understands that.
if [ "$DRY_RUN" != "1" ]; then
  chmod 700 "$TARGET/secrets" 2>/dev/null || warn "could not chmod 700 secrets/ (filesystem may not support it)"
fi

# ------------------------------------------------------- 5.2 harness files --
rt_sub "Copying the harness"

copy_tree() { # copy_tree <rel-subdir> <mode> [name-filter-ext]
  local sub="$1" mode="$2" f rel base n=0
  [ -d "$HARNESS_DIR/$sub" ] || { MISSING_FILES="${MISSING_FILES}${sub}/ (whole directory)
"; return 1; }
  local fmode
  for f in "$HARNESS_DIR/$sub"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    rel="$sub/$base"
    fmode="$mode"
    # PER-FILE EXCEPTION. domain.config.sh is the one file under .claude/ that
    # a human owns: it is the interview's output and it holds this project's
    # walls. Replacing it on upgrade would silently reset every wall the human
    # configured, and the failure would be invisible until the day a guard did
    # not refuse something it used to refuse. Harness-owned means replaceable;
    # this file is not harness-owned, it merely lives in a harness directory.
    case "$base" in domain.config.sh) fmode="if-absent" ;; esac
    copy_file "$f" "$rel" "$fmode" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && ok "$sub ($n files)"
  return 0
}

# Harness-owned: replaced on upgrade. That is what an upgrade IS.
copy_tree ".claude/hooks"       replace
copy_tree ".claude/hooks/stack" replace
copy_tree ".claude/agents"      replace
# Doctrine docs. Harness-owned exactly like the hooks: identical in every
# project, carrying no project content, and the only channel by which a doctrine
# change reaches an existing install. Copied unconditionally so an update
# actually refreshes them; the human's contracts next door in .context/ are the
# ones that are written if-absent.
copy_tree ".claude/doctrine"    replace

# The release-commit template. Harness-owned, replaced on upgrade like the rest
# of .claude/. Wiring it to git is a separate, separately-reversible step below,
# because a user who already has their own commit.template must keep it.
copy_file "$HARNESS_DIR/.claude/commit-template.txt" ".claude/commit-template.txt" replace \
  >/dev/null && ok ".claude/commit-template.txt"

# ------------------------------------------------------------- 5.3 context --
# Human-owned. Written ONLY when absent -- an upgrade must never rewrite a SPEC.
# .context/ holds exactly three contracts: SPEC.md, MILESTONES.md, DECISIONS.md
# (CONTRACT.md 1). The doctrine that used to sit beside them now lives in
# .claude/doctrine/ -- an ALLOWLIST, not a glob: a stale pre-1.2.0 build of the
# harness source shipped CLAUDE.md/CONVENTIONS.md/PIPELINE.md/TEMPLATE.md/
# UPGRADING.md here too, and a glob-based copy put them in every fresh
# install, if-absent, where the updater's HARNESS/USER classifier (which only
# knows SPEC/MILESTONES/DECISIONS as USER) then protected them as USER files
# forever -- never refreshed, never flagged, silently contradicting the real
# doctrine on the very same read path. Extend this list only by editing
# CONTRACT.md 1 first.
rt_sub "Human-owned contracts (.context/)"
for base in SPEC.md MILESTONES.md DECISIONS.md; do
  f="$HARNESS_DIR/.context/$base"
  [ -f "$f" ] || { warn ".context/$base missing from the harness source (fail closed on install)"; continue; }
  if [ -f "$TARGET/.context/$base" ]; then
    info "kept existing .context/$base (yours; not overwritten)"
  else
    copy_file "$f" ".context/$base" if-absent && ok ".context/$base (new)"
  fi
done

# --- CLAUDE.md: never clobber ---------------------------------------------
# Two different files are called CLAUDE.md and the difference matters. The
# harness's copy is the orchestrator's operating manual and belongs in
# .claude/doctrine/, where it is harness-owned and replaced on update. A
# project's own root CLAUDE.md is instructions the human wrote for their repo,
# and overwriting it would delete something we cannot regenerate.
CLAUDE_CONFLICT=0
if [ -f "$HARNESS_DIR/.claude/doctrine/CLAUDE.md" ]; then
  if [ -f "$TARGET/CLAUDE.md" ]; then
    # A root CLAUDE.md that already carries the import is not a conflict --
    # it is what THIS installer writes on a fresh install (below), so every
    # re-run/update used to hit this branch and print a false "installed but
    # not loaded" warning even for a pristine install. Only a root CLAUDE.md
    # that does NOT import the doctrine is a real conflict.
    if grep -q '@\.claude/doctrine/CLAUDE\.md' "$TARGET/CLAUDE.md" 2>/dev/null; then
      ok "CLAUDE.md already imports .claude/doctrine/CLAUDE.md -- doctrine is loaded"
    else
      CLAUDE_CONFLICT=1
      copy_file "$HARNESS_DIR/.claude/doctrine/CLAUDE.md" "CLAUDE.ratchet.md" replace \
        && warn "you already have a root CLAUDE.md. It was NOT touched."
      say "        Ratchet's operating manual was written to CLAUDE.ratchet.md instead."
      say "        Claude Code reads root CLAUDE.md automatically and does NOT read"
      say "        CLAUDE.ratchet.md, so until you act, the harness's doctrine is"
      say "        installed but not loaded. Do ONE of these:"
      say "          (a) add this line to your CLAUDE.md:   @.claude/doctrine/CLAUDE.md"
      say "          (b) merge CLAUDE.ratchet.md into your CLAUDE.md by hand"
      say "        (a) is what we recommend: it keeps the two files separately"
      say "        upgradeable, and .claude/doctrine/CLAUDE.md is the file Ratchet updates."
    fi
  else
    if [ "$DRY_RUN" != "1" ]; then
      printf '@.claude/doctrine/CLAUDE.md\n' > "$TARGET/CLAUDE.md" && record "F CLAUDE.md"
      ok "CLAUDE.md -> @.claude/doctrine/CLAUDE.md (one-line import; edit freely, it is yours)"
    else
      dry "write CLAUDE.md"
    fi
  fi
fi

# ------------------------------------------------- 5.4 learning-loop stubs --
rt_sub "Learning loop (.agent-development/)"
for f in "$HARNESS_DIR/.agent-development"/*; do
  [ -f "$f" ] || continue
  copy_file "$f" ".agent-development/$(basename "$f")" if-absent >/dev/null
done
ok ".agent-development/ seeded (existing files kept)"

# ============================================================================
# SECTION 6 — settings.json: MERGE, never overwrite
# ============================================================================
rt_phase 4 "Permission surface"

TEMPLATE="$HARNESS_DIR/.claude/settings.template.json"
if [ ! -f "$TEMPLATE" ]; then
  MISSING_FILES="${MISSING_FILES}.claude/settings.template.json
"
  err "settings.template.json is missing from the harness source. Skipping the"
  say "        permission surface entirely. The hooks are installed but NOTHING IS"
  say "        WIRED: no guard runs, no gate fires. This install is not usable."
else
  # 6.1 -- expand the template into a concrete settings document.
  STACK_PACK="$TARGET/.claude/hooks/stack/$STACK.sh"
  STACK_ALLOW=""
  if [ -f "$STACK_PACK" ]; then
    # STACK_ALLOW_ENTRIES is an installer-level extension to CONTRACT §2.3: a
    # newline list of permission strings this stack needs in allow[]. If a pack
    # does not define it we fall back to the table below, so a pack written to
    # the frozen contract still installs correctly.
    STACK_ALLOW="$( . "$STACK_PACK" >/dev/null 2>&1; printf '%s' "${STACK_ALLOW_ENTRIES:-}" )"
  fi
  if [ -z "$STACK_ALLOW" ]; then
    case "$STACK" in
      python-pytest) STACK_ALLOW='Bash(make:*)
Bash(uv sync:*)
Bash(uv lock:*)
Bash(uv add:*)
Bash(uv remove:*)
Bash(uv export:*)
Bash(uv run pytest:*)
Bash(uv run mypy:*)
Bash(uv run ruff:*)
Bash(uv run pip-audit:*)
Bash(uv run pre-commit:*)
Bash(pytest:*)
Bash(python -m pytest:*)
Bash(python3 -m pytest:*)
Bash(ruff:*)
Bash(mypy:*)
Bash(pip-audit:*)
Bash(pre-commit install)
Bash(pre-commit run:*)
Edit(./pyproject.toml)
Edit(./uv.lock)
Edit(./requirements.txt)
Edit(./.github/workflows/**)
Write(./.github/workflows/**)' ;;
      node-jest) STACK_ALLOW='Bash(make:*)
Bash(npm ci)
Bash(npm install:*)
Bash(npm run:*)
Bash(npm test:*)
Bash(npx jest:*)
Bash(npx tsc:*)
Bash(npx eslint:*)
Bash(npx prettier:*)
Bash(pnpm install:*)
Bash(pnpm run:*)
Bash(yarn install:*)
Bash(yarn run:*)
Bash(node --test:*)
Edit(./package.json)
Edit(./tsconfig.json)
Edit(./.github/workflows/**)
Write(./.github/workflows/**)' ;;
      *) STACK_ALLOW='Bash(make:*)
Edit(./.github/workflows/**)
Write(./.github/workflows/**)' ;;
    esac
  fi

  # Pull the domain pack's lists (may not exist yet -- empty is valid).
  DOM_ARTIFACTS=""; DOM_BANNED=""; DOM_CORPUS=""; DOM_SECRETS=""
  DOMAIN_NAME_V="none"
  if [ -f "$TARGET/.claude/hooks/domain.config.sh" ]; then
    DOM_ARTIFACTS="$( . "$TARGET/.claude/hooks/domain.config.sh" >/dev/null 2>&1; printf '%s' "${FORBIDDEN_ARTIFACTS:-}" )"
    DOM_BANNED="$(   . "$TARGET/.claude/hooks/domain.config.sh" >/dev/null 2>&1; printf '%s' "${BANNED_READ_FILES:-}" )"
    DOM_CORPUS="$(   . "$TARGET/.claude/hooks/domain.config.sh" >/dev/null 2>&1; printf '%s' "${GOVERNING_CORPUS:-}" )"
    DOM_SECRETS="$(  . "$TARGET/.claude/hooks/domain.config.sh" >/dev/null 2>&1; printf '%s' "${SECRET_PATTERNS:-}" )"
    DOMAIN_NAME_V="$(. "$TARGET/.claude/hooks/domain.config.sh" >/dev/null 2>&1; printf '%s' "${DOMAIN_NAME:-none}" )"
  fi

  # Turn newline lists into the permission strings each class needs.
  #   forbidden artifacts -> Edit()+Write() deny  (never-escalatable class 1)
  #   banned read files   -> Read() deny
  #   governing corpus    -> Edit()+Write() deny
  #   secret patterns     -> Read()+Edit()+Write() deny
  expand_paths() { # expand_paths <verbs...> < list-on-stdin
    local verbs="$*" p v
    while IFS= read -r p; do
      p="${p%$'\r'}"
      case "$p" in ""|\#*) continue ;; esac
      case "$p" in ./*) p="${p#./}" ;; esac
      for v in $verbs; do
        case "$p" in
          /*|\**) printf '%s(%s)\n' "$v" "$p" ;;
          *)      printf '%s(./%s)\n' "$v" "$p" ;;
        esac
      done
    done
  }
  DOMAIN_DENY="$(printf '%s\n' "$DOM_ARTIFACTS" | expand_paths Edit Write)"
  BANNED_DENY="$(printf '%s\n' "$DOM_BANNED"    | expand_paths Read Edit Write)"
  CORPUS_DENY="$(printf '%s\n' "$DOM_CORPUS"    | expand_paths Edit Write)"
  SECRET_DENY="$(printf '%s\n' "$DOM_SECRETS"   | expand_paths Read Edit Write)"
  CORPUS_DENY="$CORPUS_DENY
$SECRET_DENY"

  GEN="$TARGET/.claude/settings.json.rt-generated"
  if [ "$DRY_RUN" = "1" ]; then GEN="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/rt-settings.$$")"; fi

  # Scalar substitution first (sed is fine: every value here is single-line).
  esc_sed() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
  sed \
    -e "s|{{RATCHET_VERSION}}|$(esc_sed "$RT_INSTALLER_VERSION")|g" \
    -e "s|{{RATCHET_PROJECT_NAME}}|$(esc_sed "$PROJECT_NAME")|g" \
    -e "s|{{PROJECT_NAME}}|$(esc_sed "$PROJECT_NAME")|g" \
    -e "s|{{RATCHET_PROJECT_DIR}}|$(esc_sed "$TARGET")|g" \
    -e "s|{{RATCHET_STACK_NAME}}|$(esc_sed "$STACK")|g" \
    -e "s|{{RATCHET_DOMAIN_NAME}}|$(esc_sed "$DOMAIN_NAME_V")|g" \
    -e "s|{{RATCHET_BASE_BRANCH}}|$(esc_sed "$BASE_BRANCH")|g" \
    -e "s|{{BASE_BRANCH}}|$(esc_sed "$BASE_BRANCH")|g" \
    -e "s|{{RATCHET_AGENT_BRANCH_PREFIX}}|agent/|g" \
    -e "s|{{RATCHET_ESCALATION_MODE}}|$(esc_sed "$ESCALATION_MODE")|g" \
    -e "s|{{RATCHET_SECRETS_DIR}}|secrets|g" \
    -e "s|{{RATCHET_ESCALATION_KEY}}|secrets/escalation.key|g" \
    -e "s|{{RATCHET_GENERATED_AT}}|$(date -u +%Y-%m-%dT%H:%M:%SZ)|g" \
    "$TEMPLATE" > "$GEN" 2>/dev/null

  if ! jq -e . "$GEN" >/dev/null 2>&1; then
    err "the expanded settings template is not valid JSON. Not touching settings.json."
    say "        This is a harness bug, not a you bug. Report it with:"
    say "            jq . '$GEN'"
  else
    # 6.2 -- expand the LIST placeholders. Each is a single string element that
    # becomes zero or more elements. Keeping them as string elements is what
    # makes settings.template.json valid JSON on its own, and therefore lintable
    # in CI before anyone runs the installer.
    SA_F="$GEN.stack"; DD_F="$GEN.dd"; BD_F="$GEN.bd"; CD_F="$GEN.cd"
    printf '%s\n' "$STACK_ALLOW"  | sed '/^[[:space:]]*$/d' > "$SA_F"
    printf '%s\n' "$DOMAIN_DENY"  | sed '/^[[:space:]]*$/d' > "$DD_F"
    printf '%s\n' "$BANNED_DENY"  | sed '/^[[:space:]]*$/d' > "$BD_F"
    printf '%s\n' "$CORPUS_DENY"  | sed '/^[[:space:]]*$/d' > "$CD_F"

    jq --rawfile sa "$SA_F" --rawfile dd "$DD_F" --rawfile bd "$BD_F" --rawfile cd "$CD_F" '
      def lines(s): (s | split("\n") | map(select(length > 0)));
      def expand(arr; marker; repl):
        arr | map(if . == marker then repl else [.] end) | add // [];
      .permissions.allow = expand(.permissions.allow; "{{RATCHET_STACK_ALLOW}}"; lines($sa))
    | .permissions.ask   = expand(.permissions.ask;   "{{RATCHET_DOMAIN_ASK}}";  [])
    | .permissions.deny  = expand(.permissions.deny;  "{{RATCHET_DOMAIN_DENY}}"; lines($dd))
    | .permissions.deny  = expand(.permissions.deny;  "{{RATCHET_BANNED_READ_DENY}}"; lines($bd))
    | .permissions.deny  = expand(.permissions.deny;  "{{RATCHET_CORPUS_DENY}}"; lines($cd))
    | .permissions.allow |= unique
    | .permissions.ask   |= unique
    | .permissions.deny  |= unique
    ' "$GEN" > "$GEN.2" 2>/dev/null && mv -f "$GEN.2" "$GEN"
    rm -f "$SA_F" "$DD_F" "$BD_F" "$CD_F" "$GEN.2" 2>/dev/null

    EXISTING="$TARGET/.claude/settings.json"
    if [ -f "$EXISTING" ]; then
      if ! jq -e . "$EXISTING" >/dev/null 2>&1; then
        warn "your existing .claude/settings.json is not valid JSON. It was backed up and"
        say "        REPLACED rather than merged, because merging into a file we cannot"
        say "        parse would mean guessing at your intent."
        BAK=".claude/settings.json.bak-$TS"
        act "back up settings.json -> $BAK" cp -f "$EXISTING" "$TARGET/$BAK"
        record "B $BAK .claude/settings.json"
        act "install settings.json" cp -f "$GEN" "$EXISTING"
        record "F .claude/settings.json"
      else
        BAK=".claude/settings.json.bak-$TS"
        act "back up settings.json -> $BAK" cp -f "$EXISTING" "$TARGET/$BAK"
        record "B $BAK .claude/settings.json"
        ok "backed up your settings.json to $BAK"

        # THE MERGE. Union permissions; append only hooks we do not already
        # have. Your entries survive; ours are added. The one asymmetry is
        # deliberate: OUR deny wins over YOUR allow, because deny is the class
        # that cannot be lifted at runtime and a permissive entry that survives
        # a merge would silently reopen a wall.
        MERGED="$GEN.merged"
        if jq -s '
            def hookcmds: [ .. | objects | select(has("command")) | .command ];
            # $-BOUND PARAMETERS ARE LOAD-BEARING. In jq, def f(a; b) binds a and
            # b as CLOSURES, re-evaluated against whatever the input happens to
            # be at each use site. Inside [ new[] | select(...) ] that input is
            # one NEW hook-group object, so an unbound `old` re-evaluated there
            # was null, the subtraction removed nothing, length > 0 was always
            # true, and every re-install appended a full duplicate set of hook
            # registrations -- eight guard.sh entries after four installs, each
            # firing on every tool call. $old and $new are VALUES, bound once.
            # Reproduce the old behaviour with:
            #   jq -n "def f(o;n): [ n[] | (o|type) ]; {a:[1,2]} | f(.a; [{}])"
            #   => ["null"]
            def merge_event($old; $new):
              ($old // []) + [ $new[] | select( (.hooks // []) as $h
                  | ([ $h[].command ] - [ ($old // [])[]? | .hooks[]?.command ]) | length > 0 ) ];
            .[0] as $old | .[1] as $new
            | $old
            | .permissions.defaultMode = ($new.permissions.defaultMode // $old.permissions.defaultMode)
            | .permissions.allow = ((($old.permissions.allow // []) + ($new.permissions.allow // [])) | unique)
            | .permissions.ask   = ((($old.permissions.ask   // []) + ($new.permissions.ask   // [])) | unique)
            | .permissions.deny  = ((($old.permissions.deny  // []) + ($new.permissions.deny  // [])) | unique)
            | .permissions.allow = (.permissions.allow - ($new.permissions.deny // []))
            | .permissions.ask   = (.permissions.ask   - ($new.permissions.deny // []))
            | .hooks = ( ($old.hooks // {}) as $oh | ($new.hooks // {}) as $nh
                | reduce ($nh | keys_unsorted[]) as $k ($oh;
                    .[$k] = merge_event(.[$k]; $nh[$k]) ) )
            | ._ratchet = $new._ratchet
            | ._ratchet_permission_doctrine = $new._ratchet_permission_doctrine
            | ._ratchet_deny_partition = $new._ratchet_deny_partition
            | ._ratchet_note_decisions = $new._ratchet_note_decisions
            | ._ratchet_merged_from = "\($old | tostring | length) bytes of pre-existing settings were merged, not replaced"
          ' "$EXISTING" "$GEN" > "$MERGED" 2>/dev/null && jq -e . "$MERGED" >/dev/null 2>&1; then
          act "merge settings.json" cp -f "$MERGED" "$EXISTING"
          record "F .claude/settings.json"
          if [ "$DRY_RUN" != "1" ]; then
            A_OLD="$(jq '.permissions.allow|length' "$TARGET/$BAK" 2>/dev/null || echo 0)"
            A_NEW="$(jq '.permissions.allow|length' "$EXISTING" 2>/dev/null || echo 0)"
            ok "merged: allow $A_OLD -> $A_NEW entries; your entries kept, our deny wins ties"
          fi
        else
          err "the merge produced invalid JSON. Your settings.json was NOT modified."
          say "        Your backup is at $BAK and the generated file we wanted to merge is"
          say "        at $GEN -- merge them by hand, or move your settings aside and re-run."
        fi
        rm -f "$MERGED" 2>/dev/null
      fi
    else
      act "install settings.json" cp -f "$GEN" "$EXISTING"
      record "F .claude/settings.json"
      # "B - <path>" records the ABSENCE of a prior file. Without this line an
      # uninstall after two installs restores the FIRST BACKUP IT FINDS -- which,
      # when the project never had a settings.json, is a Ratchet-generated
      # document from install #1. The repo would then keep the harness's
      # permission surface forever, having been told it was uninstalled. "-"
      # sorts before any timestamped backup name, so it always wins.
      record "B - .claude/settings.json"
      ok "wrote .claude/settings.json"
    fi
  fi
  [ "$DRY_RUN" = "1" ] && rm -f "$GEN" 2>/dev/null
  [ "$DRY_RUN" = "1" ] || rm -f "$GEN" 2>/dev/null
fi

# ============================================================================
# SECTION 7 — executable bits
# ============================================================================
rt_sub "Permissions on hook files"
if [ "$DRY_RUN" = "1" ]; then
  dry "chmod +x .claude/hooks/*.sh and *.py"
else
  n=0
  for f in "$TARGET/.claude/hooks"/*.sh "$TARGET/.claude/hooks"/*.py \
           "$TARGET/.claude/hooks/stack"/*.sh; do
    [ -f "$f" ] || continue
    chmod +x "$f" 2>/dev/null && n=$((n+1))
  done
  ok "chmod +x on $n hook files"
  # approve.sh is human-only. Layer 1 is the settings deny, layer 2 is guard.sh,
  # layer 3 is its own TTY check. It stays executable BY YOU on purpose.
  if [ -f "$TARGET/.claude/hooks/approve.sh" ]; then
    ok "approve.sh installed (human-only: denied to the agent at three layers)"
  fi
fi

# ============================================================================
# SECTION 8 — secrets: key generation and a VERIFIED gitignore
# ============================================================================
rt_phase 5 "Escalation key and gitignore"

GITIGNORE="$TARGET/.gitignore"

ensure_ignore() { # ensure_ignore <pattern> <comment>
  local pat="$1" cmt="${2:-}"
  if [ -f "$GITIGNORE" ] && grep -qxF "$pat" "$GITIGNORE" 2>/dev/null; then
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    dry "append to .gitignore: $pat"
    return 0
  fi
  { [ -s "$GITIGNORE" ] && [ -n "$(tail -c 1 "$GITIGNORE" 2>/dev/null)" ] && printf '\n'; } >> "$GITIGNORE" 2>/dev/null
  [ -n "$cmt" ] && printf '%s\n' "$cmt" >> "$GITIGNORE"
  printf '%s\n' "$pat" >> "$GITIGNORE"
  return 0
}

if [ "$DRY_RUN" != "1" ] && [ ! -f "$GITIGNORE" ]; then
  : > "$GITIGNORE" && record "F .gitignore"
fi

ensure_ignore "secrets/" "# --- Ratchet: the escalation signing key lives here. Never commit it. ---"
ensure_ignore ".env"
ensure_ignore ".env.local"

# THE .pipeline/ IGNORE/TRACK PARTITION.
# .pipeline/ is not uniformly disposable, and treating it as such is a real bug
# in both directions. Per-host runtime files (retry counters, event logs, the
# resolved interpreter path) differ per machine and would conflict on every
# merge. But findings.md, the manifest, the checkpoint verdicts and
# ship-consent.json are the RECORD of a run -- they are the evidence anyone
# would use later to check that a merge was consented to and a finding was
# adjudicated. Those are tracked. Negation patterns must come after the
# directory pattern and cannot re-include a file under an ignored DIRECTORY,
# which is why we ignore per-file rather than ignoring .pipeline/ wholesale.
if [ "$DRY_RUN" != "1" ] && ! grep -qxF "# --- Ratchet: .pipeline/ runtime (per-host; never committed) ---" "$GITIGNORE" 2>/dev/null; then
  { printf '\n%s\n' "# --- Ratchet: .pipeline/ runtime (per-host; never committed) ---"
    printf '%s\n' \
      ".pipeline/stop-retries*" \
      ".pipeline/subagent-retries*" \
      ".pipeline/run-events.jsonl" \
      ".pipeline/run-metrics.json" \
      ".pipeline/verify-last.json" \
      ".pipeline/run-start" \
      ".pipeline/run-idle" \
      ".pipeline/run-last-seen" \
      ".pipeline/run-active" \
      ".pipeline/ready-to-ship" \
      ".pipeline/.last-paged" \
      ".pipeline/cmd-log" \
      ".pipeline/notifications.log" \
      ".pipeline/dispatch/" \
      ".pipeline/.py-interp" \
      ".pipeline/red-baseline.txt" \
      ".pipeline/escalations/"
    printf '\n%s\n' "# --- Ratchet: .pipeline/ durable record (TRACKED on purpose) ---"
    printf '%s\n' "# These negations are assertions, not fixes: .pipeline/ itself is NOT ignored," \
                  "# so these files are already tracked. They are written down because the" \
                  "# tempting simplification -- one '.pipeline/' line -- would silently drop the" \
                  "# findings ledger, the checkpoint verdicts and ship-consent.json, which are" \
                  "# the only durable evidence that a merge was consented to and a finding was" \
                  "# adjudicated. Anyone who reaches for that simplification reads this first."
    printf '%s\n' \
      "!.pipeline/findings.md" \
      "!.pipeline/plan-files.txt" \
      "!.pipeline/manifest-amendments.txt" \
      "!.pipeline/checkpoints/" \
      "!.pipeline/ship-consent.json" \
      "!.pipeline/recap.md" \
      "!.pipeline/run-journal.md"
  } >> "$GITIGNORE"
  ok ".pipeline/ ignore/track partition written to .gitignore"
elif [ "$DRY_RUN" = "1" ]; then
  dry "write .pipeline/ ignore-and-track partition into .gitignore"
else
  ok ".pipeline/ partition already present in .gitignore"
fi

# --- VERIFY, do not assume, that secrets/ is actually ignored --------------
# "We appended a line to .gitignore" is not the same claim as "git will not
# commit this file". A parent .gitignore, a global core.excludesFile, a
# negation later in the file, or an ALREADY-TRACKED path all break it, and the
# last one breaks it silently: git ignores .gitignore for files in the index.
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$TARGET/secrets" 2>/dev/null
  PROBE="$TARGET/secrets/.ratchet-ignore-probe"
  : > "$PROBE" 2>/dev/null
  if git -C "$TARGET" check-ignore -q "secrets/.ratchet-ignore-probe" 2>/dev/null; then
    ok "verified: git will not commit anything under secrets/"
  else
    err "secrets/ is NOT ignored by git, even after writing the .gitignore entry."
    say "        The escalation signing key is about to be created there. If it is"
    say "        committed, every approval in this repo's history becomes forgeable by"
    say "        anyone who can read the repo -- and rotating it will not undo that."
    say ""
    say "        Most likely causes, in the order worth checking:"
    say "          1. secrets/ is already TRACKED. git ignores .gitignore for files"
    say "             already in the index. Fix:  git -C \"$TARGET\" rm -r --cached secrets"
    say "          2. a later negation in .gitignore re-includes it. Check:"
    say "             git -C \"$TARGET\" check-ignore -v secrets/escalation.key"
    say "          3. a global core.excludesFile or a parent .gitignore disagrees."
    WARNINGS=$((WARNINGS+1))
  fi
  rm -f "$PROBE" 2>/dev/null
fi

# --- generate the key ------------------------------------------------------
KEYFILE="$TARGET/secrets/escalation.key"
if [ "$DRY_RUN" = "1" ]; then
  dry "generate secrets/escalation.key via approve.sh --init-key"
elif [ -f "$KEYFILE" ]; then
  ok "escalation key already present (not regenerated -- that is deliberate)"
elif [ -x "$TARGET/.claude/hooks/approve.sh" ]; then
  if ( cd "$TARGET" && ./.claude/hooks/approve.sh --init-key ) >/dev/null 2>&1 && [ -f "$KEYFILE" ]; then
    chmod 600 "$KEYFILE" 2>/dev/null
    ok "generated secrets/escalation.key (mode 0600) via approve.sh --init-key"
  else
    warn "approve.sh --init-key did not produce a key. Falling back."
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 > "$KEYFILE" 2>/dev/null
    elif [ -r /dev/urandom ]; then
      od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$KEYFILE" 2>/dev/null
    fi
    if [ -s "$KEYFILE" ]; then chmod 600 "$KEYFILE" 2>/dev/null; ok "generated the key directly"
    else warn "could not generate a key. Run: .claude/hooks/approve.sh --init-key"; fi
  fi
else
  MISSING_FILES="${MISSING_FILES}.claude/hooks/approve.sh
"
  warn "approve.sh is not installed, so no escalation key was generated."
  say "        Without it, every escalatable refusal becomes a hard wall: the guard"
  say "        will refuse and no human approval can lift it. Run this once approve.sh"
  say "        exists:   .claude/hooks/approve.sh --init-key"
fi

# ============================================================================
# SECTION 9 — the domain interview
# ============================================================================
if [ "$DOMAIN_MODE" = "interactive" ] && [ "$DRY_RUN" != "1" ]; then
  rt_sub "Domain pack interview"
  if [ -x "$TARGET/.claude/hooks/interview.sh" ]; then
    PROJECT_NAME="$PROJECT_NAME" "$TARGET/.claude/hooks/interview.sh" </dev/tty >/dev/tty 2>&1 \
      || warn "the interview exited non-zero; the previous domain pack is unchanged."
  else
    warn "interview.sh not installed; skipping. Run it later:  .claude/hooks/interview.sh"
  fi
elif [ "$DOMAIN_MODE" = "interactive" ]; then
  dry "run .claude/hooks/interview.sh"
fi

# ============================================================================
# SECTION 10 — {{MARKER}} substitution
# ============================================================================
rt_phase 6 "Substituting doctrine markers"

# Values come from three places, in this precedence: CLI answers > the domain
# pack > the stack pack. Everything is written to a JSON map and handed to
# python, because several values (DOMAIN_LAWS, the review lens) are MULTI-LINE
# and sed cannot do a multi-line replacement portably.
subst_run() {
  local mapfile="$1"
  "$PY" - "$TARGET" "$mapfile" <<'PYEOF'
import sys, os, json, io
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

target, mapfile = sys.argv[1], sys.argv[2]
with open(mapfile, encoding="utf-8") as fh:
    subs = json.load(fh)

ROOTS = [".claude/agents", ".claude/doctrine", ".claude/hooks", ".context", ".agent-development", "docs"]
FILES = [".claude/settings.json", "CLAUDE.md", "CLAUDE.ratchet.md"]
SKIP_EXT = {".pyc", ".png", ".jpg", ".gif", ".zip", ".gz", ".key", ".pem"}
SKIP_NAME = {"domain.config.sh"}   # generated from answers; never re-templated

def candidates():
    for f in FILES:
        p = os.path.join(target, f)
        if os.path.isfile(p):
            yield p
    for r in ROOTS:
        base = os.path.join(target, r)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in ("__pycache__", ".git")]
            for fn in filenames:
                if fn in SKIP_NAME:
                    continue
                if os.path.splitext(fn)[1].lower() in SKIP_EXT:
                    continue
                yield os.path.join(dirpath, fn)

import re
MARKER = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
changed, unresolved = 0, {}
for path in candidates():
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (UnicodeDecodeError, OSError):
        continue
    if "{{" not in text:
        continue
    def repl(m):
        k = m.group(1)
        if k in subs:
            return subs[k]
        unresolved.setdefault(k, []).append(os.path.relpath(path, target))
        return m.group(0)
    new = MARKER.sub(repl, text)
    if new != text:
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(new)
        changed += 1

print("SUBST_CHANGED=%d" % changed)
for k, files in sorted(unresolved.items()):
    seen = sorted(set(files))[:4]
    print("SUBST_UNRESOLVED=%s\t%s" % (k, ", ".join(seen)))
PYEOF
}

# Assemble the map.
DOMAIN_SH="$TARGET/.claude/hooks/domain.config.sh"
STACK_SH="$TARGET/.claude/hooks/stack/$STACK.sh"
MAPFILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/rt-subs.$$")"

# Read every value in ONE subshell so a pack that sets things conditionally is
# evaluated once, consistently.
(
  # shellcheck disable=SC1090
  [ -f "$DOMAIN_SH" ] && . "$DOMAIN_SH" >/dev/null 2>&1
  # shellcheck disable=SC1090
  [ -f "$STACK_SH" ]  && . "$STACK_SH"  >/dev/null 2>&1

  jqarg() { printf '%s' "${1-}"; }
  # Both spellings of every marker are emitted. The prefixed form
  # ({{RATCHET_BASE_BRANCH}}) and the bare form ({{BASE_BRANCH}}) are BOTH in
  # active use across the harness's documents, and an installer that filled
  # only one spelling would leave literal braces sitting inside an agent's
  # system prompt, where they read as instructions to nobody.
  jq -n \
    --arg project        "$PROJECT_NAME" \
    --arg projdir        "$TARGET" \
    --arg version        "$RT_INSTALLER_VERSION" \
    --arg stack          "${STACK_NAME:-$STACK}" \
    --arg base           "$BASE_BRANCH" \
    --arg prefix         "agent/" \
    --arg escmode        "$ESCALATION_MODE" \
    --arg forge          "github" \
    --arg secretsdir     "secrets" \
    --arg esckey         "secrets/escalation.key" \
    --arg verify         "${VERIFY_CMD:-}" \
    --arg fasttest       "${FAST_TEST_CMD:-}" \
    --arg scopedtest     "${SCOPED_TEST_CMD:-}" \
    --arg arbiter        "${ARBITER_LABEL:-Escalate to a higher-tier model}" \
    --arg domname        "${DOMAIN_NAME:-none}" \
    --arg domdesc        "${DOMAIN_DESCRIPTION:-a software project with no declared domain pack}" \
    --arg domlaws        "${DOMAIN_LAWS:-}" \
    --arg domlens        "${DOMAIN_REVIEW_LENS:-}" \
    --arg dompass        "${DOMAIN_SECURITY_PASS:-}" \
    --arg dommat         "${DOMAIN_MATERIALITY:-it changes a rule that later milestones will inherit rather than re-derive}" \
    --arg domhard        "${DOMAIN_HARD_STOPS:-This domain declared no additional irreversible action; the harness-fixed list above is the whole wall.}" \
    '{
      PROJECT_NAME:$project,            RATCHET_PROJECT_NAME:$project,
      PROJECT_DIR:$projdir,             RATCHET_PROJECT_DIR:$projdir,
      RT_VERSION:$version,              RATCHET_VERSION:$version,
      STACK_NAME:$stack,                RATCHET_STACK_NAME:$stack,
      BASE_BRANCH:$base,                RATCHET_BASE_BRANCH:$base,
      AGENT_BRANCH_PREFIX:$prefix,      RATCHET_AGENT_BRANCH_PREFIX:$prefix,
      ESCALATION_MODE:$escmode,         RATCHET_ESCALATION_MODE:$escmode,
      FORGE:$forge,                     RATCHET_FORGE:$forge,
      SECRETS_DIR:$secretsdir,          RATCHET_SECRETS_DIR:$secretsdir,
      ESCALATION_KEY:$esckey,           RATCHET_ESCALATION_KEY:$esckey,
      VERIFY_CMD:$verify,               RATCHET_VERIFY_CMD:$verify,
      FAST_TEST_CMD:$fasttest,          SCOPED_TEST_CMD:$scopedtest,
      ARBITER_LABEL:$arbiter,           RATCHET_ARBITER_LABEL:$arbiter,
      DOMAIN_NAME:$domname,             RATCHET_DOMAIN_NAME:$domname,
      DOMAIN_DESCRIPTION:$domdesc,      DOMAIN_LAWS:$domlaws,
      DOMAIN_REVIEW_LENS:$domlens,      DOMAIN_SECURITY_PASS:$dompass,
      DOMAIN_MATERIALITY:$dommat,       DOMAIN_HARD_STOPS:$domhard
    }'
) > "$MAPFILE" 2>/dev/null

if [ "$DRY_RUN" = "1" ]; then
  dry "substitute $(jq 'keys|length' "$MAPFILE" 2>/dev/null || echo '?') markers across .claude/, .context/, docs/"
else
  SUBST_OUT="$(subst_run "$MAPFILE" 2>&1)"
  SUBST_N="$(printf '%s\n' "$SUBST_OUT" | sed -n 's/^SUBST_CHANGED=//p')"
  ok "substituted markers in ${SUBST_N:-0} files"
  UNRES="$(printf '%s\n' "$SUBST_OUT" | sed -n 's/^SUBST_UNRESOLVED=//p')"
  if [ -n "$UNRES" ]; then
    warn "some {{MARKERS}} had no value and were LEFT IN PLACE:"
    printf '%s\n' "$UNRES" | sed 's/^/          /'
    say "        A surviving marker is not cosmetic. In an agent definition it becomes"
    say "        literal text in a system prompt, and the model reads '{{VERIFY_CMD}}'"
    say "        as a string rather than as your test command. Either the doctrine"
    say "        author used a name the installer does not know, or your domain pack"
    say "        has no value for it. Fix the pack and re-run:"
    say "            ./install.sh --target . --substitute-only"
  fi
fi
rm -f "$MAPFILE" 2>/dev/null

# Record the answers so --substitute-only and the next upgrade agree with this run.
if [ "$DRY_RUN" != "1" ]; then
  jq -n --arg p "$PROJECT_NAME" --arg s "$STACK" --arg b "$BASE_BRANCH" \
        --arg e "$ESCALATION_MODE" --arg d "$DOMAIN_MODE" --arg v "$RT_INSTALLER_VERSION" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{project_name:$p, stack:$s, base_branch:$b, escalation_mode:$e, domain_mode:$d,
      installer_version:$v, installed_at:$t}' > "$INSTALL_STATE" 2>/dev/null \
    && record "F .claude/.ratchet-install.json"
fi

if [ "$SUBST_ONLY" = "1" ]; then
  rt_head "Substitution-only run complete"
  say "  Nothing else was touched."
  [ "$DRY_RUN" != "1" ] && [ -n "$MANIFEST_TMP" ] && rm -f "$MANIFEST_TMP"
  exit 0
fi

# ============================================================================
# SECTION 11 — PENDING-HUMAN-ACTIONS
# ============================================================================
rt_sub "Pre-filing the three human actions"

PHA=".agent-development/PENDING-HUMAN-ACTIONS.md"
if [ -f "$TARGET/$PHA" ] && grep -q "ratchet-install-human-actions" "$TARGET/$PHA" 2>/dev/null; then
  ok "$PHA already carries the install actions"
elif [ "$DRY_RUN" = "1" ]; then
  dry "append three install actions to $PHA"
else
  mkdir -p "$TARGET/.agent-development" 2>/dev/null
  if [ ! -f "$TARGET/$PHA" ]; then
    cat > "$TARGET/$PHA" <<'PHAHDR'
# PENDING HUMAN ACTIONS

This register exists so that "someone must do X" stops being filed as a
decision. A to-do recorded as a decision is both a bloated decision log and a
task nobody tracks.

Agents APPEND here. Humans close rows by editing the Status column to DONE and
saying what they did. Nothing here is ever deleted; a closed row is evidence.

| name | opened | who | action | status |
|---|---|---|---|---|
PHAHDR
    record "F $PHA"
  fi
  D="$(date -u +%Y-%m-%d)"
  cat >> "$TARGET/$PHA" <<PHAROWS
| webhook-url-unset | $D | human | Set \`RATCHET_WEBHOOK_URL\` to an https endpoint (Slack/Discord/ntfy) so \`notify.sh\` can page you when a run stops for a Decision Card. Unset, the harness still works, but an unattended run that stops is a run you find out about by looking. <!-- ratchet-install-human-actions --> | OPEN |
| base-branch-unprotected | $D | human | Enable branch protection on \`$BASE_BRANCH\` (require a PR, block force push). This is the ONLY server-side control in the ship flow. \`ship-consent.json\` is a record, not a control; the permission prompt is a per-command approval. Branch protection is what actually stops an unreviewed merge. | OPEN |
| spec-and-milestones-empty | $D | human | Fill \`.context/SPEC.md\` (frozen requirement ids) and \`.context/MILESTONES.md\` (WIN rows, each with a script-decidable verify command). Until both exist the run has no definition of done, and every gate that reads them will refuse rather than guess. | OPEN |
PHAROWS
  ok "filed 3 open actions in $PHA"
fi

# ============================================================================
# SECTION 11.5 — RELEASE-COMMIT TEMPLATE
#
# Points git at .claude/commit-template.txt so a human running `git commit`
# with no -m gets the "Version X.X.X: ..." release form pre-filled.
#
# Three deliberate properties:
#   1. It is repo-LOCAL (`git config` without --global). Ratchet never edits a
#      user's global git configuration.
#   2. An existing commit.template is NEVER overwritten. If the user already has
#      one, that is a deliberate choice and this step says so and moves on.
#   3. It does not touch the agent's commit path at all. In-run commits are made
#      with `git commit -m` (one Conventional Commit per green cycle, CLAUDE.md),
#      and -m never opens an editor, so it never reads a template. The two
#      formats cannot collide. Note also that guard.sh refuses `git config` to
#      the agent (rule git-config-write) -- this is the installer acting as the
#      human, which is the only party that may set it.
# ============================================================================
if [ "$DRY_RUN" = "1" ]; then
  dry "git config commit.template .claude/commit-template.txt"
elif [ "$UNINSTALL" != "1" ]; then
  EXISTING_TPL="$(git -C "$TARGET" config --local --get commit.template 2>/dev/null || true)"
  if [ -z "$EXISTING_TPL" ]; then
    if git -C "$TARGET" config --local commit.template ".claude/commit-template.txt" 2>/dev/null; then
      ok "git commit.template -> .claude/commit-template.txt (repo-local)"
    else
      warn "could not set commit.template; set it yourself with:"
      say  "        git config --local commit.template .claude/commit-template.txt"
    fi
  elif [ "$EXISTING_TPL" = ".claude/commit-template.txt" ]; then
    ok "git commit.template already points at the Ratchet template"
  else
    ok "git commit.template left as-is ($EXISTING_TPL) -- yours, not ours"
    say "        Ratchet's release template is at .claude/commit-template.txt if you want it."
  fi
fi

# ============================================================================
# SECTION 12 — VERIFICATION
# ============================================================================
VERIFY_RC=0
VERIFY_STATE="not run"

# Resolve `none` BEFORE the guard below reads RUN_VERIFY. This flag used to fall
# through to the same empty VERIFY_FLAG as `full` and then skip the budget cap,
# so asking for NO verification ran the slowest possible verification, uncapped.
# Zeroing RUN_VERIFY *inside* the `if` that has already tested it is equally
# ineffective -- which is exactly what the first attempt at this fix did, and why
# this line sits here rather than in the case below.
if [ "$VERIFY_TIER" = "none" ]; then RUN_VERIFY=0; fi

if [ "$RUN_VERIFY" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  rt_phase 7 "Install verification"
  VERIFY_FLAG=""
case "$VERIFY_TIER" in
  quick) VERIFY_FLAG="--quick" ;;
  smoke) VERIFY_FLAG="--smoke" ;;
  full)  VERIFY_FLAG="" ;;
  none)  VERIFY_FLAG="" ;;   # unreachable: RUN_VERIFY was zeroed above
  *) warn "unknown --verify tier '$VERIFY_TIER'; using quick."; VERIFY_TIER=quick; VERIFY_FLAG="--quick" ;;
esac

# Windows spawns processes roughly an order of magnitude slower than POSIX, and
# this suite is almost entirely process spawns: a tier that is 25s on Linux has
# been measured at 414s under Git-Bash. Budget the step so nobody watches a
# spinner for seven minutes wondering whether it hung, and say the number up
# front rather than after.
VERIFY_BUDGET="${RATCHET_VERIFY_BUDGET:-120}"
IS_WINDOWSISH=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWSISH=1 ;; esac
if [ "$IS_WINDOWSISH" = "1" ]; then
  VERIFY_BUDGET="${RATCHET_VERIFY_BUDGET:-420}"
  if [ "$VERIFY_TIER" = "full" ]; then
    warn "the full suite on Windows is very slow (~25 min: process spawn, not the gates)."
    say "        Consider --verify quick here, and run the full suite once when you"
    say "        can leave it. Override the cap with RATCHET_VERIFY_BUDGET=<seconds>."
  fi
fi
[ "$VERIFY_TIER" = "none" ] || VERIFY_FLAG="$VERIFY_FLAG --brief --max-seconds $VERIFY_BUDGET"
if [ -f "$TARGET/.claude/hooks/test_hooks.py" ]; then
    # BOUND IT. The hook suite is large and grows; on a slow host it can run for
    # minutes. An installer that hangs with no output is indistinguishable from
    # an installer that crashed, and the person watching will Ctrl-C it halfway
    # through -- which is the one moment when a half-finished install is worst.
    VT="${RATCHET_INSTALL_VERIFY_TIMEOUT:-900}"
    VERIFY_TIMED_OUT=0
    rt_spin_start "running the hook suite (bounded at ${VT}s; this is the slow step)..."
    if command -v timeout >/dev/null 2>&1; then
      VOUT="$(cd "$TARGET" && timeout "$VT" $PY .claude/hooks/test_hooks.py $VERIFY_FLAG 2>&1)"
      VERIFY_RC=$?
      rt_spin_kill
      if [ "$VERIFY_RC" = "124" ]; then
        VERIFY_STATE="TIMED OUT after ${VT}s"
        warn "the hook suite did not finish within ${VT}s. That is not a pass and it is"
        say "        not a failure -- it is a check that did not run, so treat it as unknown."
        say "        Raise the bound if the suite has legitimately grown:"
        say "            RATCHET_INSTALL_VERIFY_TIMEOUT=1800 ./install.sh --target ... --no-verify"
        say "        then run it yourself:  $PY .claude/hooks/test_hooks.py"
        VERIFY_TIMED_OUT=1
        VERIFY_RC=0
      fi
    else
      VOUT="$(cd "$TARGET" && $PY .claude/hooks/test_hooks.py $VERIFY_FLAG 2>&1)"
      VERIFY_RC=$?
      rt_spin_kill
    fi
    if [ "${VERIFY_TIMED_OUT:-0}" = "1" ]; then
      : # already reported above; an unfinished check is neither pass nor fail
    elif [ "$VERIFY_RC" = "0" ]; then
      VERIFY_STATE="PASS"
      pass "the hook suite is green on this host."
      printf '%s\n' "$VOUT" | tail -5 \
        | sed "s/^\\(.*[^[:space:]].*\\)\$/${C_DIM}\\1${C_0}/;s/^/       /"
    else
      VERIFY_STATE="FAIL"
      printf '\n'
      rt_rule "$C_R"
      printf '  %s%s  INSTALL VERIFICATION FAILED%s\n\n' "$C_R" "$C_B" "$C_0"
      printf '  test_hooks.py exited %s. The harness is installed but at least one\n' "$VERIFY_RC"
      printf '  gate does not behave the way its own tests say it should.\n\n'
      # --brief already produced a human-sized, grouped summary with a likely
      # cause. Print THAT. A wall of Python tracebacks tells a person nothing
      # they can act on, and it buries the one line that would have.
      VSUM="$(printf '%s\n' "$VOUT" | sed -n '/WHAT FAILED/,$p')"
      if [ -n "$VSUM" ]; then
        printf '%s\n' "$VSUM" | sed 's/^/  /'
      else
        printf '%s\n' "$VOUT" | tail -20 | sed 's/^/    /'
      fi
      if printf '%s' "$VOUT" | grep -q 'budget spent\|max-seconds'; then
        printf '\n  The run also hit its time budget, so some tests never ran. That is a\n'
        printf '  speed limit, not a verdict: raise it with RATCHET_VERIFY_BUDGET=<seconds>.\n'
      fi
      printf '\n  Do not start a milestone on a red suite. A gate whose test fails is a\n'
      printf '  gate you cannot reason about, and the whole value of this harness is\n'
      printf '  that a refusal means something. Re-run the suite yourself:\n'
      printf '      cd %s && %s .claude/hooks/test_hooks.py --quick -v\n' "$TARGET" "$PY"
      rt_rule "$C_R"
      printf '\n'
    fi
  else
    MISSING_FILES="${MISSING_FILES}.claude/hooks/test_hooks.py
"
    VERIFY_STATE="SKIPPED (test_hooks.py not installed)"
    warn "test_hooks.py is not present, so the install was NOT verified."
    say "        An unverified control layer is the one thing this harness cannot"
    say "        check for you. Run the suite as soon as the file exists."
  fi

  # --- postcondition baseline ---------------------------------------------
  # R-005-03: an approved .claude/ write is judged on whether it made the hook
  # suite WORSE, not on whether the suite is perfect. On a host with
  # pre-existing failures, with no baseline recorded, every one of them counts
  # as new and the postcondition can never clear -- which turns an approvable
  # write into a permanent wall for reasons that have nothing to do with the
  # write. Recording the floor NOW, at install time, is the cheapest moment.
  # BUT: a baseline is a record of "what this host already fails". Recording one
  # from a RED verification run bakes today's breakage in as normal, and the
  # postcondition then passes while the control layer is genuinely broken -- the
  # check would be worse than useless, because it would look green. So the floor
  # is only recorded from a run that actually passed.
  if [ "${VERIFY_STATE%% *}" = "FAIL" ]; then
    warn "NOT recording a postcondition baseline: verification failed."
    say "        A baseline taken from a red suite records today's failures as this"
    say "        host's normal state, and the postcondition would then pass while the"
    say "        control layer is broken. Fix the suite, then run:"
    say "            .claude/hooks/approve.sh --postcondition-baseline"
  elif [ "${VERIFY_STATE%% *}" = "PASS" ]; then
    # The suite just ran and nothing failed. The baseline IS that failure set, so
    # it is provably empty -- re-running the whole suite to rediscover "nothing
    # fails" is pure waste, and it was doubling install time. Write it directly.
    PCB="$TARGET/.pipeline/escalations/postcondition-baseline.txt"
    mkdir -p "$(dirname "$PCB")" 2>/dev/null || true
    if : > "$PCB" 2>/dev/null; then
      ok "recorded the postcondition baseline (empty: the suite is green here)"
    else
      warn "could not write the postcondition baseline. Run it yourself:"
      say "            .claude/hooks/approve.sh --postcondition-baseline"
    fi
  elif [ -x "$TARGET/.claude/hooks/approve.sh" ]; then
    # Verification was skipped or not run, so we do not know the floor: ask for it.
    PCB_TO=""
    command -v timeout >/dev/null 2>&1 && PCB_TO="timeout ${RATCHET_INSTALL_VERIFY_TIMEOUT:-900}"
    rt_spin_start "recording the control-layer postcondition baseline (runs the suite again)..."
    if ( cd "$TARGET" && $PCB_TO ./.claude/hooks/approve.sh --postcondition-baseline ) >/dev/null 2>&1; then
      rt_spin_kill
      ok "recorded the control-layer postcondition baseline"
    else
      rt_spin_kill
      warn "could not record the postcondition baseline automatically. Run it yourself:"
      say "            .claude/hooks/approve.sh --postcondition-baseline"
      say "        Skipping it is only harmless on a host where the suite is fully green."
    fi
  fi
fi

# ============================================================================
# SECTION 13 — finalise the manifest
# ============================================================================
if [ "$DRY_RUN" != "1" ] && [ -n "$MANIFEST_TMP" ]; then
  sort -u "$MANIFEST_TMP" > "$MANIFEST_TMP.s" 2>/dev/null && mv -f "$MANIFEST_TMP.s" "$MANIFEST_TMP"
  mv -f "$MANIFEST_TMP" "$MANIFEST" 2>/dev/null
fi

# --- version + checksum baseline for ratchet-update.sh ----------------------
# Without these, the FIRST update cannot tell "you edited this hook" from "the
# bundle changed it", so it reports every differing harness file as UNVERIFIED
# and preserves copies nobody asked for. Recording the baseline at install time
# is the only moment it is free and unambiguous.
# Format: "<sha256>  <repo-relative-path>" -- two spaces, sha256sum -c compatible.
if [ "$DRY_RUN" != "1" ]; then
  printf '%s\n' "$RT_INSTALLER_VERSION" > "$TARGET/.claude/.ratchet-version" 2>/dev/null || true

  RT_SUM=""
  if command -v sha256sum >/dev/null 2>&1; then RT_SUM="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then RT_SUM="shasum -a 256"
  fi
  if [ -n "$RT_SUM" ]; then
    (
      cd "$TARGET" 2>/dev/null || exit 0
      {
        for d in .claude/hooks .claude/hooks/stack .claude/agents .claude/doctrine; do
          [ -d "$d" ] || continue
          for f in "$d"/*; do
            [ -f "$f" ] || continue
            case "$f" in
              */domain.config.sh) continue ;;   # USER class: the walls you configured
              *.local-*|*.bak-*)  continue ;;
            esac
            $RT_SUM "$f" 2>/dev/null
          done
        done
      } | sed 's|  \./|  |' > .claude/.ratchet-manifest.tmp 2>/dev/null
      mv -f .claude/.ratchet-manifest.tmp .claude/.ratchet-manifest 2>/dev/null
    ) || true
    if [ -f "$TARGET/.claude/.ratchet-manifest" ]; then
      ok "recorded update baseline (.ratchet-version $RT_INSTALLER_VERSION, $(wc -l < "$TARGET/.claude/.ratchet-manifest" | tr -d ' ') checksums)"
    fi
  else
    warn "no sha256 tool, so no update baseline was recorded. The first"
    say "        ratchet-update.sh run cannot distinguish your edits from upstream"
    say "        changes; run 'ratchet-update.sh --adopt-baseline' once to fix that."
  fi
fi

# ============================================================================
# SECTION 14 — REPORT
# ============================================================================
if [ "$DRY_RUN" = "1" ]; then
  printf '\n'
  rt_box_top light "RATCHET $RT_INSTALLER_VERSION -- DRY RUN"
  rt_box_line light ""
  rt_box_line light "  DRY RUN COMPLETE. Nothing above was written." "$C_Y$C_B"
  rt_box_line light "  Re-run without --dry-run to apply."
  rt_box_line light ""
  rt_box_kv   light "would install to" "$TARGET"
  rt_box_kv   light "project name"     "$PROJECT_NAME"
  rt_box_kv   light "stack pack"       "$STACK"
  rt_box_kv   light "domain pack"      "$DOMAIN_MODE"
  rt_box_kv   light "base branch"      "$BASE_BRANCH"
  rt_box_kv   light "escalation"       "$ESCALATION_MODE"
  rt_box_kv   light "warnings"         "$WARNINGS"
  rt_box_line light ""
  rt_box_bottom light
  printf '\n'
  exit 0
fi

# Colour follows the value, and nothing else: this is a lookup for the table
# below, not a decision. VERIFY_STATE was settled in section 12.
RT_VCOL="$C_DIM"
case "$VERIFY_STATE" in
  PASS)  RT_VCOL="$C_G" ;;
  FAIL*) RT_VCOL="$C_R" ;;
  TIMED*|SKIPPED*) RT_VCOL="$C_Y" ;;
esac
RT_WCOL="$C_G"; [ "$WARNINGS" -gt 0 ] 2>/dev/null && RT_WCOL="$C_Y"

printf '\n'
rt_box_top light "RATCHET $RT_INSTALLER_VERSION -- INSTALLED"
rt_box_line light ""
rt_box_kv   light "installed into" "$TARGET"
rt_box_kv   light "project name"   "$PROJECT_NAME"
rt_box_kv   light "stack pack"     "$STACK"
rt_box_kv   light "domain pack"    "$DOMAIN_MODE"
rt_box_kv   light "base branch"    "$BASE_BRANCH"
rt_box_kv   light "escalation"     "$ESCALATION_MODE"
rt_box_kv   light "verification"   "$VERIFY_STATE" "$RT_VCOL"
rt_box_kv   light "warnings"       "$WARNINGS"     "$RT_WCOL"
rt_box_line light ""
rt_box_bottom light

if [ -n "$MISSING_FILES" ]; then
  rt_head "Files the harness source did not contain"
  printf '%s' "$MISSING_FILES" | sed '/^$/d' | sort -u | sed 's/^/    missing: /'
  say ""
  say "  Each of those is a component that is now NOT installed. If this is a"
  say "  development checkout that is expected; if it is a release, the release is"
  say "  incomplete and you should not run a milestone against it."
fi

rt_head "THREE THINGS ONLY A HUMAN CAN DO"
say "  1. PAGER. Set the webhook so a stopped run reaches you."
say "         export RATCHET_WEBHOOK_URL='https://hooks.slack.com/services/...'"
say "     Put it in your shell profile, not in the repo. Without it the harness"
say "     still works; you just find out it stopped by going and looking."
say ""
say "  2. BRANCH PROTECTION on '$BASE_BRANCH'. Require a pull request, block force"
say "     pushes. Do this even though the harness already gates merges, because"
say "     the harness's gate is a record and a prompt, and this is a server-side"
say "     rule. It is the only one of the three that an agent cannot route around."
say "         gh api -X PUT repos/{owner}/{repo}/branches/$BASE_BRANCH/protection \\"
say "           -f 'required_pull_request_reviews[required_approving_review_count]=0' \\"
say "           -F 'enforce_admins=true' -F 'restrictions=null' -F 'required_status_checks=null'"
say "     (or click it in Settings > Branches -- honestly, do that.)"
say ""
say "  3. THE TWO CONTRACTS. They ship as placeholders on purpose: the harness"
say "     does not guess your project. Have Claude draft them from"
say "     .claude/doctrine/TEMPLATE.md, then correct them yourself -- you own"
say "     them (Tier 2b):"
say "         .context/SPEC.md         requirement ids, frozen, cited by every test"
say "         .context/MILESTONES.md   WIN rows, each with a verify command that"
say "                                  exits 0 for pass. A WIN row without one is a"
say "                                  setup defect, and the harness will say so"
say "                                  rather than quietly judge it by vibes."
say ""
say "  All three are already filed in .agent-development/PENDING-HUMAN-ACTIONS.md."

rt_head "YOUR FIRST COMMAND TO CLAUDE CODE"
say "  cd $TARGET && claude"
say ""
say "  Then paste exactly this:"
say ""
say "      Read .claude/doctrine/CLAUDE.md and .claude/doctrine/TEMPLATE.md."
say "      .context/SPEC.md and .context/MILESTONES.md are placeholders --"
say "      interview me, then write them from TEMPLATE.md. Invent nothing: if"
say "      you do not know a requirement or a verify command, ask me or leave a"
say "      marked TODO(human). Stop when they are written, before running."
say ""
say "  It will come back with a draft SPEC and a first milestone for you to"
say "  correct. Keep M0 small -- two WIN rows is plenty. Seeing the gates fire"
say "  on something trivial is far cheaper than meeting them mid-milestone."
printf '\n'
rt_rule
printf '\n'

if [ "$VERIFY_RC" != "0" ] && [ "$RUN_VERIFY" = "1" ] && [ "$VERIFY_STATE" = "FAIL" ]; then
  exit 1
fi
exit 0
