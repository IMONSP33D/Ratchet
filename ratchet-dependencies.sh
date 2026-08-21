#!/usr/bin/env bash
# =============================================================================
# ratchet-dependencies.sh -- install what Ratchet's host check requires.
#
# Run this BEFORE install.sh (or install.ps1) when the host check refuses. It
# works out what is missing, shows you the exact command it wants to run, asks
# before running it, and -- when it cannot install something itself -- prints
# the precise command or download URL for your platform instead of guessing.
#
# It is safe to run repeatedly. It only ever acts on what is actually missing,
# so a second run on a fixed host installs nothing and exits 0.
#
# WHAT IT MANAGES (exactly what install.sh's host check tests for):
#   FATAL   bash 4+    every Ratchet hook is a bash script
#   FATAL   git        the gates read the worktree on every hook firing
#   FATAL   jq         hooks parse a JSON payload; without jq the security
#                      guards fail CLOSED, so the agent can run nothing at all
#   FATAL   python3    four gates are Python (check_done, check_narrative,
#                      proof_map, run_metrics); the ship gate needs them
#   WARN    gh         needed only by the ship flow (open PR, merge)
#   OFFER   pytest ruff        stack pack: python-pytest
#   OFFER   node npm           stack pack: node-jest
#
# WHAT IT WILL NOT DO, ON PURPOSE:
#   - It never runs sudo without showing you the command and asking first.
#   - It never pipes a downloaded script into a shell. Where an upstream
#     installer is the right answer (Homebrew, the GitHub CLI apt repo) it
#     prints the line and lets you read it.
#   - It never installs Python packages into a system interpreter. PEP 668
#     marks those environments externally managed for good reasons.
#   - It never installs an optional stack tool without a separate yes.
#
# Usage:
#   ./ratchet-dependencies.sh                        detect, ask, install
#   ./ratchet-dependencies.sh --check                report only, install nothing
#   ./ratchet-dependencies.sh --dry-run              print commands, run none
#   ./ratchet-dependencies.sh --yes                  unattended; assume yes
#   ./ratchet-dependencies.sh --target ../my-repo --stack python-pytest
#
# Options:
#   --check              report status and exit; install nothing
#   --dry-run | -n       print every command that would run; change nothing
#   --yes | -y           assume yes at every prompt, including optional tools
#   --no-optional        do not even offer the stack pack tools
#   --target <dir>       the repo you intend to install Ratchet into. Used to
#                        pick the stack and to print the exact next command.
#                        (default: the current directory)
#   --stack <name>       python-pytest | node-jest | generic | none
#                        (default: auto-detected from --target)
#   -h | --help
#
# Exit codes:
#   0  every FATAL dependency is present
#   1  a FATAL dependency is still missing after this run (read the table)
#   2  refused before doing anything (bad arguments)
# =============================================================================

# This script has to RUN on the hosts it exists to fix -- including macOS's
# bash 3.2, the very version it is here to replace. So nothing below uses a
# bash 4 feature: no associative arrays, no mapfile, no ${var^^}, no `local -n`.
# Lists are newline- or space-delimited strings, iterated with `for` and `case`.
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'ratchet-dependencies: run me with bash, not sh:  bash %s\n' "$0" >&2
  exit 2
fi
set -uo pipefail

RT_DEPS_VERSION="1.0.0"

# ----------------------------------------------------------------- output ---
# Same helpers, same shapes, same degradation rules as install.sh.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B="$(printf '\033[1m')"; C_R="$(printf '\033[31m')"; C_Y="$(printf '\033[33m')"
  C_G="$(printf '\033[32m')"; C_0="$(printf '\033[0m')"
else
  C_B=""; C_R=""; C_Y=""; C_G=""; C_0=""
fi

WARNINGS=0

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }
ok()    { printf '  %sok%s    %s\n' "$C_G" "$C_0" "$*"; }
info()  { printf '  ..    %s\n' "$*"; }
warn()  { printf '  %sWARN%s  %s\n' "$C_Y" "$C_0" "$*"; WARNINGS=$((WARNINGS+1)); }
err()   { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*" >&2; }
# An empty continuation line is a paragraph break, not eight spaces of trailing
# whitespace. Some terminals and every diff tool care about the difference.
cont()  { if [ -z "$*" ]; then printf '\n'; else printf '        %s\n' "$*"; fi; }
die()   { printf '\n%sratchet-dependencies refused:%s %s\n\n' "$C_R" "$C_0" "$*" >&2; exit 2; }

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# ------------------------------------------------------------------ args ----
MODE_CHECK=0
DRY_RUN=0
ASSUME_YES=0
WANT_OPTIONAL=1
TARGET_ARG=""
STACK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)        MODE_CHECK=1 ;;
    --dry-run|-n)   DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --no-optional)  WANT_OPTIONAL=0 ;;
    --target)       shift; [ $# -gt 0 ] || die "--target needs a directory"; TARGET_ARG="$1" ;;
    --target=*)     TARGET_ARG="${1#--target=}" ;;
    --stack)        shift; [ $# -gt 0 ] || die "--stack needs a name"; STACK="$1" ;;
    --stack=*)      STACK="${1#--stack=}" ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$STACK" in
  ""|python-pytest|node-jest|generic|none) ;;
  *) die "--stack must be python-pytest, node-jest, generic or none (got: $STACK)" ;;
esac

[ -n "$TARGET_ARG" ] || TARGET_ARG="."
TARGET_ABS="$(cd "$TARGET_ARG" 2>/dev/null && pwd)" || TARGET_ABS=""

# --------------------------------------------------------------- utilities --
have() { command -v "$1" >/dev/null 2>&1; }

# Deduplicate a space-separated word list, preserving first-seen order. Windows
# needs this: bash and git are the same package (Git for Windows), and asking
# winget to install it twice is noise at best.
dedupe() {
  local out="" w
  for w in $1; do
    case " $out " in *" $w "*) ;; *) out="$out $w" ;; esac
  done
  printf '%s' "${out# }"
}

confirm() { # confirm <prompt> -> 0 yes, 1 no
  local ans=""
  if [ "$ASSUME_YES" = "1" ]; then
    say ""
    info "--yes given; proceeding without asking."
    return 0
  fi
  if [ ! -t 0 ]; then
    say ""
    warn "stdin is not a terminal and --yes was not given, so nothing will be run."
    cont "Copy the commands above, or re-run with --yes."
    return 1
  fi
  printf '\n  %s [y/N] ' "$1"
  read -r ans || return 1
  case "$ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

run_cmd() { # run_cmd <argv...> -- honours --dry-run, prints before running
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %sDRY%s   %s\n' "$C_Y" "$C_0" "$*"
    return 0
  fi
  printf '  %srun%s   %s\n' "$C_B" "$C_0" "$*"
  "$@"
}

# =============================================================================
# SECTION 1 -- PLATFORM. Everything downstream keys off this, so it is done
# first and reported in full. A wrong answer here produces confident bad
# advice, which is worse than no advice.
# =============================================================================
head1 "Ratchet dependency installer $RT_DEPS_VERSION -- platform"

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
OS_KIND="unknown"
case "$UNAME_S" in
  Linux)                 OS_KIND="linux" ;;
  Darwin)                OS_KIND="macos" ;;
  MINGW*|MSYS*|CYGWIN*)  OS_KIND="windows" ;;
  FreeBSD|OpenBSD|NetBSD|DragonFly) OS_KIND="bsd" ;;
esac

# WSL is not "a Linux" for our purposes and it is not "a Windows" either. It is
# the one host where the user can have two of every tool, from two filesystems,
# and pick the wrong pairing. Detect it explicitly and say so out loud.
IN_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  IN_WSL=1
elif grep -qi microsoft /proc/version 2>/dev/null; then
  IN_WSL=1
fi

DISTRO_ID=""
DISTRO_NAME=""
if [ -r /etc/os-release ]; then
  # tr -d '\r' because a /etc/os-release that has been through a Windows editor
  # is not the strangest thing this script will meet today.
  DISTRO_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" | tr -d '\r')"
  DISTRO_NAME="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}" | tr -d '\r')"
fi

# --- package manager -------------------------------------------------------
# Detection order is the order in the build contract: apt, dnf, yum, pacman,
# apk, brew, then the Windows managers. First hit wins; a host with both dnf
# and yum is a Fedora/RHEL host and dnf is the right answer.
PM=""
PM_CMD=""
if   have apt-get; then PM="apt";    PM_CMD="apt-get"
elif have dnf;     then PM="dnf";    PM_CMD="dnf"
elif have yum;     then PM="yum";    PM_CMD="yum"
elif have pacman;  then PM="pacman"; PM_CMD="pacman"
elif have apk;     then PM="apk";    PM_CMD="apk"
elif have brew;    then PM="brew";   PM_CMD="brew"
elif have winget;  then PM="winget"; PM_CMD="winget"
elif have choco;   then PM="choco";  PM_CMD="choco"
fi

# On Windows the managers are .exe and may not be on the Git-Bash PATH under a
# bare name in every shell; probe the .exe spellings too before giving up.
if [ "$OS_KIND" = "windows" ] && [ -z "$PM" ]; then
  if   have winget.exe; then PM="winget"; PM_CMD="winget.exe"
  elif have choco.exe;  then PM="choco";  PM_CMD="choco.exe"
  fi
fi

# --- privilege -------------------------------------------------------------
# ROOT_NEEDED is a property of the package manager, not of the host. brew
# refuses to run as root; winget elevates itself through UAC; the system
# managers all write to /usr and /var.
ROOT_NEEDED=0
case "$PM" in apt|dnf|yum|pacman|apk) ROOT_NEEDED=1 ;; esac

AM_ROOT=0
[ "$(id -u 2>/dev/null || echo 1)" = "0" ] && AM_ROOT=1

ELEVATE=""      # word prefixed to system-manager commands; may stay empty
CANNOT_ELEVATE=0
if [ "$ROOT_NEEDED" = "1" ] && [ "$AM_ROOT" = "0" ]; then
  if   have sudo; then ELEVATE="sudo"
  elif have doas; then ELEVATE="doas"
  else CANNOT_ELEVATE=1
  fi
fi

# --- report ----------------------------------------------------------------
case "$OS_KIND" in
  linux)
    if [ "$IN_WSL" = "1" ]; then
      ok "WSL (${WSL_DISTRO_NAME:-$DISTRO_NAME}) -- a Linux running inside Windows"
    else
      ok "Linux${DISTRO_NAME:+ -- $DISTRO_NAME}"
    fi ;;
  macos)   ok "macOS $(sw_vers -productVersion 2>/dev/null || uname -r)" ;;
  windows) ok "Windows, under $UNAME_S (Git-Bash / MSYS)" ;;
  bsd)     ok "$UNAME_S" ;;
  *)       warn "unrecognised platform '$UNAME_S'. Everything below will be advice, not action." ;;
esac

if [ -n "$PM" ]; then
  ok "package manager: $PM ($PM_CMD)"
else
  warn "no supported package manager found (looked for apt-get, dnf, yum, pacman, apk, brew, winget, choco)."
  cont "Nothing will be installed automatically; you will get exact commands instead."
fi

# macOS without Homebrew is the one platform where the FIX for the missing
# package manager is itself a download. We print that line; we do not run it.
# Piping a URL into a shell is exactly the habit a harness like this exists to
# discourage, and it would be absurd to teach it in the dependency installer.
MACOS_NO_BREW=0
if [ "$OS_KIND" = "macos" ] && [ "$PM" != "brew" ]; then
  MACOS_NO_BREW=1
  warn "Homebrew is not installed, and on macOS it is how these dependencies arrive."
  cont "Install it first -- read the line before you run it, as you should with any"
  cont "installer that fetches code:"
  cont ""
  cont '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  cont ""
  cont "Then re-run this script; it will take over from there."
fi

# Windows with neither winget nor choco: same shape, different answer. There is
# no one-line bootstrap, so every dependency below becomes a download URL.
if [ "$OS_KIND" = "windows" ] && [ -z "$PM" ]; then
  warn "neither winget nor choco is available in this shell."
  cont "winget ships with Windows 11 and recent Windows 10; if you have it in"
  cont "PowerShell but not here, run the commands from PowerShell instead."
  cont "Otherwise use the download links printed below."
fi

if [ "$ROOT_NEEDED" = "1" ]; then
  if [ "$AM_ROOT" = "1" ]; then
    ok "running as root; no sudo needed"
  elif [ "$CANNOT_ELEVATE" = "1" ]; then
    warn "$PM needs root and neither sudo nor doas is available here."
    cont "The commands below must be run by an administrator."
  else
    ok "will elevate with '$ELEVATE' (you will be shown the exact command first)"
  fi
fi

# =============================================================================
# SECTION 1b -- THE WSL / WINDOWS SPLIT. This is the single most expensive
# misconfiguration this harness can be given, so it gets its own section rather
# than a line in a table.
# =============================================================================
if [ "$IN_WSL" = "1" ]; then
  TARGET_ON_WINDOWS=0
  case "$TARGET_ABS" in /mnt/[a-z]/*|/mnt/[a-z]) TARGET_ON_WINDOWS=1 ;; esac

  head1 "WSL detected -- read this before installing anything"
  say "  Everything has to live in ONE world. WSL and Windows do not share a"
  say "  filesystem: WSL sees /home/you/repo, Windows sees C:\\Users\\you\\repo, and"
  say "  no single path satisfies both. A WSL shell driving a Windows Python (or a"
  say "  Windows Python spawning a WSL bash) cannot work -- the hooks get handed"
  say "  paths that do not exist on the other side, and every error message names"
  say "  a file that plainly does exist. That is the most confusing failure mode"
  say "  Ratchet has, and it is entirely avoidable by choosing a side now."
  say ""
  if [ "$TARGET_ON_WINDOWS" = "1" ]; then
    warn "your target repo is on the WINDOWS filesystem: $TARGET_ABS"
    cont "You are in WSL and the repo is not. Pick one:"
    cont ""
    cont "  a) Move the project into WSL and stay here (recommended if you like WSL):"
    cont "         cp -r \"$TARGET_ABS\" ~/  &&  cd ~/$(basename "$TARGET_ABS" 2>/dev/null)"
    cont "     then re-run this script and install.sh from inside WSL."
    cont ""
    cont "  b) Leave the project on Windows and drive it from Windows:"
    cont "         open PowerShell (not WSL) and run  .\\ratchet-dependencies.ps1"
    cont "         then  .\\install.ps1 -Target <repo>"
    cont ""
    cont "Installing Linux packages from here will NOT help case (b): they land in"
    cont "the WSL distro, where the Windows-side Claude Code cannot see them."
  else
    ok "target repo is inside the WSL filesystem: ${TARGET_ABS:-$TARGET_ARG}"
    cont "That is the coherent all-WSL setup. Install the distro's OWN python3,"
    cont "git and jq (this script does exactly that), run Claude Code from this"
    cont "shell, and never point it at a Windows-side python.exe."
  fi
fi

# =============================================================================
# SECTION 2 -- PROBES. Test by RUNNING things, never by their presence on PATH.
# The Windows Store python stub is a real file called python3.exe that answers
# `command -v` and does nothing except open the Store.
# =============================================================================
head1 "Dependencies"

# Status/detail are held in one flat variable per dependency rather than an
# associative array, because this script must run under bash 3.2.
ST_BASH="";   DT_BASH=""
ST_GIT="";    DT_GIT=""
ST_JQ="";     DT_JQ=""
ST_PY="";     DT_PY=""
ST_GH="";     DT_GH=""
ST_PYTEST=""; DT_PYTEST=""
ST_RUFF="";   DT_RUFF=""
ST_NODE="";   DT_NODE=""
ST_NPM="";    DT_NPM=""

set_status() { # set_status <dep> <status> <detail>
  case "$1" in
    bash)   ST_BASH="$2";   DT_BASH="$3" ;;
    git)    ST_GIT="$2";    DT_GIT="$3" ;;
    jq)     ST_JQ="$2";     DT_JQ="$3" ;;
    python3) ST_PY="$2";    DT_PY="$3" ;;
    gh)     ST_GH="$2";     DT_GH="$3" ;;
    pytest) ST_PYTEST="$2"; DT_PYTEST="$3" ;;
    ruff)   ST_RUFF="$2";   DT_RUFF="$3" ;;
    node)   ST_NODE="$2";   DT_NODE="$3" ;;
    npm)    ST_NPM="$2";    DT_NPM="$3" ;;
  esac
}
status_of() {
  case "$1" in
    bash) printf '%s' "$ST_BASH" ;;   git) printf '%s' "$ST_GIT" ;;
    jq) printf '%s' "$ST_JQ" ;;       python3) printf '%s' "$ST_PY" ;;
    gh) printf '%s' "$ST_GH" ;;       pytest) printf '%s' "$ST_PYTEST" ;;
    ruff) printf '%s' "$ST_RUFF" ;;   node) printf '%s' "$ST_NODE" ;;
    npm) printf '%s' "$ST_NPM" ;;
  esac
}
detail_of() {
  case "$1" in
    bash) printf '%s' "$DT_BASH" ;;   git) printf '%s' "$DT_GIT" ;;
    jq) printf '%s' "$DT_JQ" ;;       python3) printf '%s' "$DT_PY" ;;
    gh) printf '%s' "$DT_GH" ;;       pytest) printf '%s' "$DT_PYTEST" ;;
    ruff) printf '%s' "$DT_RUFF" ;;   node) printf '%s' "$DT_NODE" ;;
    npm) printf '%s' "$DT_NPM" ;;
  esac
}

# --- bash 4+ ---------------------------------------------------------------
# We are running under a bash, so "is bash installed" is answered. The question
# is whether it is new enough, and if not, whether a new enough one is already
# sitting on this box unused (the usual macOS story after `brew install bash`).
find_bash4() {
  local c v
  for c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash \
           "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    v="$("$c" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null | tr -d ' \r\n')"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    if [ "$v" -ge 4 ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  set_status bash ok "${BASH_VERSION%%(*}"
  ok "bash ${BASH_VERSION%%(*}"
else
  BASH4="$(find_bash4 || true)"
  if [ -n "$BASH4" ]; then
    set_status bash old "running ${BASH_VERSION%%(*}; bash 4+ is at $BASH4"
    warn "you are running bash ${BASH_VERSION%%(*}, but a newer bash exists: $BASH4"
    cont "Nothing to install. Just use it:"
    cont "    $BASH4 ./install.sh --target $TARGET_ARG"
  else
    set_status bash missing "running ${BASH_VERSION%%(*}; need 4+"
    err "bash ${BASH_VERSION%%(*} is too old. Every Ratchet hook needs bash 4 or newer."
    if [ "$OS_KIND" = "macos" ]; then
      cont "macOS still ships bash 3.2 for licensing reasons; this is expected."
    fi
  fi
fi

# --- git -------------------------------------------------------------------
if have git; then
  set_status git ok "$(git --version 2>/dev/null | awk '{print $3}')"
  ok "git $(git --version 2>/dev/null | awk '{print $3}')"
else
  set_status git missing "not on PATH"
  err "git not found. Ratchet's gates read the worktree on every hook firing."
fi

# --- jq (FATAL, and this is not negotiable) --------------------------------
# install.sh refuses without it and says why; repeat the reason here, because
# this is the script someone reaches for when they are looking for permission
# to skip it.
if have jq; then
  set_status jq ok "$(jq --version 2>/dev/null)"
  ok "jq $(jq --version 2>/dev/null)"
else
  set_status jq missing "not on PATH"
  err "jq not found. This is a HARD requirement, not a nicety."
  cont "Every Ratchet hook parses its payload as JSON. A security decision made"
  cont "without a real JSON parser is a guess, so the guards fail CLOSED when jq"
  cont "is absent -- meaning every Bash tool call the agent makes is blocked."
  cont "A Ratchet install without jq is a repo the agent cannot work in at all."
fi

# --- python3 (the install.sh probe, verbatim behaviour) --------------------
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
  # $PY is deliberately unquoted everywhere: it may be the two-word "py -3".
  PY_VER="$($PY -c 'import sys;print(sys.version.split()[0])' 2>/dev/null)"
  PY_EXE="$(command -v "${PY%% *}" 2>/dev/null || true)"
  set_status python3 ok "$PY_VER (via '$PY')"
  ok "python3 via '$PY' ($PY_VER)"

  # In WSL, a Windows python answers every probe correctly and is still wrong.
  if [ "$IN_WSL" = "1" ]; then
    PY_PLATFORM="$($PY -c 'import sys;print(sys.platform)' 2>/dev/null)"
    case "$PY_PLATFORM" in
      win32|cygwin)
        set_status python3 wrong-world "$PY_VER is a WINDOWS python, seen from WSL"
        err "'$PY' is a WINDOWS Python and you are in a WSL shell."
        cont "It runs, it prints 3, and it still cannot drive this harness: it"
        cont "resolves C:\\... while your hooks resolve /home/... . Install the"
        cont "distro's own interpreter and make sure it wins on PATH:"
        cont "    which -a python3"
        ;;
      *)
        case "$PY_EXE" in
          /mnt/*|*.exe)
            set_status python3 wrong-world "$PY_EXE lives on the Windows filesystem"
            err "'$PY' resolves to $PY_EXE -- a Windows-side interpreter seen from WSL."
            cont "Install the distro's own python3 and let it win on PATH." ;;
        esac
        ;;
    esac
  fi
else
  set_status python3 missing "no working interpreter"
  err "no working Python 3 found (probed \$RATCHET_PYTHON, python3, python, 'py -3')."
  cont "Four of Ratchet's gates are Python: check_done.py, check_narrative.py,"
  cont "proof_map.py, run_metrics.py. Without an interpreter the ship gate cannot"
  cont "evaluate the definition of done, and it fails closed."
  # The stub deserves its own sentence, because it is the case where the user
  # is certain Python is installed and is not wrong, exactly.
  STUB_PATH="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  case "$STUB_PATH" in
    *WindowsApps*|*windowsapps*)
      set_status python3 stub "Microsoft Store stub at $STUB_PATH"
      cont ""
      cont "FOUND THE MICROSOFT STORE STUB at:"
      cont "    $STUB_PATH"
      cont "That file is a placeholder that opens the Store and exits. It is on the"
      cont "default Windows 11 PATH and it fools every check except running it."
      cont "Install real Python, then switch the stub off so it stops shadowing it:"
      cont "    Settings > Apps > Advanced app settings > App execution aliases"
      cont "    -> switch OFF python.exe and python3.exe"
      ;;
  esac
fi

# --- gh (WARN only: the ship flow, and nothing before it) ------------------
if have gh; then
  if gh auth status >/dev/null 2>&1; then
    set_status gh ok "$(gh --version 2>/dev/null | head -1 | awk '{print $3}') (authenticated)"
    ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}') (authenticated)"
  else
    set_status gh unauth "installed, not logged in"
    warn "gh is installed but not authenticated. The ship flow (open PR, merge) will"
    cont "fail at the last step of your first run. Fix now:  gh auth login"
  fi
else
  set_status gh missing "ship flow only"
  warn "gh (GitHub CLI) not found. Everything up to the Ship Prompt works without it,"
  cont "but the run ends by opening a PR and merging it, and both are gh."
fi

# =============================================================================
# SECTION 3 -- OPTIONAL STACK TOOLS. These are never required. install.sh warns
# about them and installs anyway, because a gate that cannot run its command
# SKIPS loudly rather than passing falsely.
# =============================================================================
detect_stack() {
  local t="$1"
  [ -n "$t" ] || { echo "generic"; return; }
  if [ -f "$t/pyproject.toml" ] || [ -f "$t/setup.py" ] || [ -f "$t/pytest.ini" ] \
     || [ -f "$t/tox.ini" ] || [ -f "$t/requirements.txt" ]; then
    echo "python-pytest"; return
  fi
  if [ -f "$t/package.json" ]; then echo "node-jest"; return; fi
  echo "generic"
}

if [ -z "$STACK" ]; then
  STACK="$(detect_stack "$TARGET_ABS")"
  STACK_SOURCE="auto-detected from ${TARGET_ABS:-$TARGET_ARG}"
else
  STACK_SOURCE="you asked for it"
fi

OPTIONAL_DEPS=""
case "$STACK" in
  python-pytest) OPTIONAL_DEPS="pytest ruff" ;;
  node-jest)     OPTIONAL_DEPS="node npm" ;;
esac

if [ "$WANT_OPTIONAL" = "0" ]; then
  OPTIONAL_DEPS=""
fi

head1 "Stack pack: $STACK ($STACK_SOURCE)"
if [ -z "$OPTIONAL_DEPS" ]; then
  if [ "$WANT_OPTIONAL" = "0" ]; then
    info "optional tools suppressed by --no-optional"
  else
    info "the '$STACK' pack has no extra tools; every stack command is a no-op and"
    cont "gates that need one SKIP with a loud notice rather than passing."
  fi
else
  for d in $OPTIONAL_DEPS; do
    if have "$d"; then
      case "$d" in
        node)   set_status node ok "$(node --version 2>/dev/null)" ;;
        npm)    set_status npm ok "$(npm --version 2>/dev/null)" ;;
        pytest) set_status pytest ok "$(pytest --version 2>&1 | head -1 | awk '{print $2}')" ;;
        ruff)   set_status ruff ok "$(ruff --version 2>/dev/null | awk '{print $2}')" ;;
      esac
      ok "$d $(detail_of "$d")"
    else
      set_status "$d" missing "optional"
      info "$d not found (optional -- the $STACK gates will SKIP loudly, not pass)"
    fi
  done
fi

# =============================================================================
# SECTION 4 -- PLAN. Map every missing dependency to a package name for the
# detected manager, or to an exact manual instruction when we have no business
# doing it ourselves.
# =============================================================================
apt_has_candidate() { # some deps ship in some releases and not others
  local c
  c="$(apt-cache policy "$1" 2>/dev/null | awk -F': *' '/Candidate:/{print $2; exit}')"
  [ -n "$c" ] && [ "$c" != "(none)" ]
}

pkg_for() { # pkg_for <dep> -> package name for $PM, empty if we cannot
  case "$PM" in
    apt)
      case "$1" in
        bash) echo bash ;; git) echo git ;; jq) echo jq ;; python3) echo python3 ;;
        gh) apt_has_candidate gh && echo gh ;;
        pytest) echo python3-pytest ;; ruff) echo "" ;;
        node) echo nodejs ;; npm) echo npm ;;
      esac ;;
    dnf|yum)
      case "$1" in
        bash) echo bash ;; git) echo git ;; jq) echo jq ;; python3) echo python3 ;;
        gh) echo gh ;; pytest) echo python3-pytest ;; ruff) echo "" ;;
        node) echo nodejs ;; npm) echo npm ;;
      esac ;;
    pacman)
      case "$1" in
        bash) echo bash ;; git) echo git ;; jq) echo jq ;; python3) echo python ;;
        gh) echo github-cli ;; pytest) echo python-pytest ;; ruff) echo ruff ;;
        node) echo nodejs ;; npm) echo npm ;;
      esac ;;
    apk)
      case "$1" in
        bash) echo bash ;; git) echo git ;; jq) echo jq ;; python3) echo python3 ;;
        gh) echo github-cli ;; pytest) echo py3-pytest ;; ruff) echo ruff ;;
        node) echo nodejs ;; npm) echo npm ;;
      esac ;;
    brew)
      case "$1" in
        bash) echo bash ;; git) echo git ;; jq) echo jq ;; python3) echo python ;;
        gh) echo gh ;; pytest) echo "" ;; ruff) echo ruff ;;
        node) echo node ;; npm) echo "" ;;
      esac ;;
    winget)
      case "$1" in
        bash|git) echo Git.Git ;; jq) echo jqlang.jq ;;
        python3) echo Python.Python.3.12 ;; gh) echo GitHub.cli ;;
        node|npm) echo OpenJS.NodeJS.LTS ;; pytest|ruff) echo "" ;;
      esac ;;
    choco)
      case "$1" in
        bash|git) echo git ;; jq) echo jq ;; python3) echo python ;;
        gh) echo gh ;; node|npm) echo nodejs-lts ;; pytest|ruff) echo "" ;;
      esac ;;
  esac
}

manual_for() { # manual_for <dep> -> exact instruction when we cannot install it
  case "$OS_KIND" in
    windows)
      case "$1" in
        bash|git) echo "Git for Windows (this is where Git-Bash comes from): https://git-scm.com/download/win" ;;
        python3)  echo "python.org, NOT the Microsoft Store: https://www.python.org/downloads/windows/  (tick 'Add python.exe to PATH')" ;;
        jq)       echo "https://jqlang.github.io/jq/download/  then put jq.exe in 'C:\\Program Files\\Git\\usr\\bin' so Git-Bash sees it" ;;
        gh)       echo "https://cli.github.com  then: gh auth login" ;;
        node|npm) echo "https://nodejs.org/en/download" ;;
        pytest)   echo "python -m pip install --user pytest" ;;
        ruff)     echo "python -m pip install --user ruff" ;;
      esac ;;
    macos)
      local pre=""
      [ "${MACOS_NO_BREW:-0}" = "1" ] && pre="install Homebrew first (line above), then: "
      case "$1" in
        bash)     echo "${pre}brew install bash   then re-run with: /opt/homebrew/bin/bash ./install.sh ..." ;;
        python3)  echo "${pre}brew install python   (the formula is 'python'; it gives you python3)" ;;
        pytest)   echo "pipx install pytest   (or install it into the project's venv)" ;;
        ruff)     echo "${pre}brew install ruff   (or: pipx install ruff)" ;;
        npm)      echo "npm ships with node; install node" ;;
        *)        echo "${pre}brew install $1" ;;
      esac ;;
    *)
      case "$1" in
        gh)     echo "GitHub CLI is not in this release's repositories. Official instructions (read them before running): https://github.com/cli/cli/blob/trunk/docs/install_linux.md" ;;
        pytest) echo "pipx install pytest   (or install it into the project's venv: python3 -m venv .venv && .venv/bin/pip install pytest)" ;;
        ruff)   echo "pipx install ruff     (or: python3 -m venv .venv && .venv/bin/pip install ruff)" ;;
        npm)    echo "npm ships with node on most distributions; install the nodejs package" ;;
        *)      echo "install '$1' with your system package manager and put it on PATH" ;;
      esac ;;
  esac
}

FATAL_DEPS="bash git jq python3"
WARN_DEPS="gh"

PLAN_REQ=""    # packages for fatal + warn deps
PLAN_OPT=""    # packages for optional stack tools
MANUAL=""      # pre-formatted lines, printed verbatim
NEED_ANY=0

plan_dep() { # plan_dep <dep> <group: req|opt>
  local dep="$1" group="$2" st pkg
  st="$(status_of "$dep")"
  case "$st" in ok) return 0 ;; esac
  NEED_ANY=1

  # bash-is-old-but-a-new-one-exists needs no install, only a different command.
  if [ "$dep" = "bash" ] && [ "$st" = "old" ]; then return 0; fi
  # A wrong-world python is not a missing package; installing more will not help
  # until the user picks a side, which section 1b already explained.
  if [ "$st" = "wrong-world" ]; then
    MANUAL="$MANUAL
  $(printf '%-9s' "$dep")$(manual_for "$dep")"
    return 0
  fi
  # An installed-but-unauthenticated gh is a login, not an install.
  if [ "$dep" = "gh" ] && [ "$st" = "unauth" ]; then
    MANUAL="$MANUAL
  $(printf '%-9s' "gh")gh auth login"
    return 0
  fi

  pkg="$(pkg_for "$dep")"
  if [ -n "$pkg" ]; then
    if [ "$group" = "opt" ]; then PLAN_OPT="$PLAN_OPT $pkg"; else PLAN_REQ="$PLAN_REQ $pkg"; fi
  else
    MANUAL="$MANUAL
  $(printf '%-9s' "$dep")$(manual_for "$dep")"
  fi
}

for d in $FATAL_DEPS $WARN_DEPS; do plan_dep "$d" req; done
for d in $OPTIONAL_DEPS;          do plan_dep "$d" opt; done

PLAN_REQ="$(dedupe "$PLAN_REQ")"
PLAN_OPT="$(dedupe "$PLAN_OPT")"

# --- render the command for a package list ---------------------------------
# Printed before it is run, every time, without exception. If you cannot read
# the command, you cannot consent to it.
PM_REFRESHED=0     # has the package index been refreshed in this run yet?

print_cmds() { # print_cmds <pkgs> [show-refresh: 1|0]
  local pkgs="$1" p
  local refresh="${2:-1}"
  # ELEVATE may legitimately be empty (already root). Fold the separating space
  # into the prefix so a root user does not read a command with a stray gap.
  local e="${ELEVATE:+$ELEVATE }"
  case "$PM" in
    apt)
      [ "$refresh" = "1" ] && say "      ${e}apt-get update"
      say "      ${e}apt-get install -y $pkgs" ;;
    dnf|yum)
      say "      ${e}$PM_CMD install -y $pkgs" ;;
    pacman)
      say "      ${e}pacman -Sy --needed --noconfirm $pkgs" ;;
    apk)
      say "      ${e}apk add $pkgs" ;;
    brew)
      say "      brew install $pkgs" ;;
    winget)
      for p in $pkgs; do
        say "      $PM_CMD install --id $p --exact --source winget --accept-package-agreements --accept-source-agreements"
      done ;;
    choco)
      say "      $PM_CMD install -y $pkgs      (from an ELEVATED PowerShell or cmd)" ;;
  esac
}

exec_cmds() { # exec_cmds <pkgs...> -> 0 if all commands succeeded
  local pkgs="$1" p rc=0
  case "$PM" in
    apt)
      # Refresh once per run, not once per group: the second group would fail
      # for exactly the same reason as the first if the index were stale.
      if [ "$PM_REFRESHED" = "0" ]; then
        run_cmd $ELEVATE apt-get update || rc=1
        PM_REFRESHED=1
      fi
      run_cmd $ELEVATE apt-get install -y $pkgs || rc=1 ;;
    dnf|yum)
      run_cmd $ELEVATE "$PM_CMD" install -y $pkgs || rc=1 ;;
    pacman)
      run_cmd $ELEVATE pacman -Sy --needed --noconfirm $pkgs || rc=1 ;;
    apk)
      run_cmd $ELEVATE apk add $pkgs || rc=1 ;;
    brew)
      run_cmd brew install $pkgs || rc=1 ;;
    winget)
      for p in $pkgs; do
        run_cmd "$PM_CMD" install --id "$p" --exact --source winget \
                --accept-package-agreements --accept-source-agreements || rc=1
      done ;;
    choco)
      # choco needs an elevated shell and bash cannot give it one. Refusing to
      # try is the honest answer; a half-run choco install is worse than none.
      rc=2 ;;
    *) rc=2 ;;
  esac
  return $rc
}

# =============================================================================
# SECTION 5 -- ACT
# =============================================================================
DID_INSTALL=0

if [ "$NEED_ANY" = "0" ]; then
  head1 "Plan"
  ok "nothing to do -- every dependency Ratchet needs is already here."
elif [ -z "$PLAN_REQ" ] && [ -z "$PLAN_OPT" ] && [ -z "$MANUAL" ]; then
  # Something is not 'ok', but nothing needs installing: the only case that
  # reaches here is a too-old shell with a newer bash already on disk, which is
  # a different command line rather than a missing package.
  head1 "Plan"
  ok "nothing to install -- what is wrong here is fixed by the command in 'Next'."
else
  head1 "Plan"

  if [ -n "$PLAN_REQ" ]; then
    say "  Required (fatal to the harness, or needed by the ship flow):"
    say ""
    print_cmds "$PLAN_REQ"
    say ""
    if [ "$ROOT_NEEDED" = "1" ] && [ "$AM_ROOT" = "0" ]; then
      if [ "$CANNOT_ELEVATE" = "1" ]; then
        warn "these need root, and there is no sudo or doas here. Run them as an administrator."
      else
        say "  '$ELEVATE' is needed because $PM writes outside your home directory."
        say "  This script never handles your password; $ELEVATE prompts you directly."
      fi
    fi
    if [ "$PM" = "choco" ]; then
      warn "chocolatey needs an ELEVATED shell, which bash cannot give it."
      cont "Copy the line above into an Administrator PowerShell and run it there."
    fi
  fi

  if [ -n "$PLAN_OPT" ]; then
    say ""
    say "  Optional ($STACK stack tools -- Ratchet works without them):"
    say ""
    if [ -n "$PLAN_REQ" ]; then print_cmds "$PLAN_OPT" 0; else print_cmds "$PLAN_OPT" 1; fi
  fi

  if [ -n "$MANUAL" ]; then
    say ""
    say "  Cannot be installed from here. Do these by hand:"
    printf '%s\n' "$MANUAL"
  fi

  if [ "$MODE_CHECK" = "1" ]; then
    say ""
    info "--check given: nothing was installed."
  elif [ -z "$PLAN_REQ" ] && [ -z "$PLAN_OPT" ]; then
    say ""
    info "nothing here can be installed automatically on this platform."
  elif [ "$PM" = "choco" ]; then
    say ""
    info "chocolatey commands are printed, never run from here (they need elevation)."
  else
    if [ -n "$PLAN_REQ" ]; then
      if confirm "Run the REQUIRED commands above?"; then
        head1 "Installing (required)"
        exec_cmds "$PLAN_REQ"
        case $? in
          0) DID_INSTALL=1 ;;
          2) warn "no automatic install path on this platform; see the manual list above." ;;
          *) warn "at least one command failed. Read its output above; the status table below is the truth." ;;
        esac
      else
        info "skipped. Nothing was installed."
      fi
    fi
    if [ -n "$PLAN_OPT" ]; then
      if confirm "Also install the OPTIONAL $STACK tools?"; then
        head1 "Installing (optional)"
        exec_cmds "$PLAN_OPT"
        case $? in
          0) DID_INSTALL=1 ;;
          2) warn "no automatic install path for the optional tools on this platform." ;;
          *) warn "at least one optional command failed. This is not fatal to Ratchet." ;;
        esac
      else
        info "skipped the optional tools. Ratchet does not need them."
      fi
    fi
  fi
fi

# =============================================================================
# SECTION 6 -- RE-PROBE AND REPORT. Never report what we intended; report what
# is actually on the box now.
# =============================================================================
if [ "$DID_INSTALL" = "1" ] && [ "$DRY_RUN" = "0" ]; then
  hash -r 2>/dev/null || true
  # A freshly installed bash cannot become THIS shell -- we are already running.
  # Re-probing turns 'missing' into 'old', which is the accurate answer and the
  # one that produces the right Next command (re-run under the new bash).
  if [ "$(status_of bash)" = "missing" ]; then
    NEW_BASH="$(find_bash4 || true)"
    if [ -n "$NEW_BASH" ]; then
      set_status bash old "running ${BASH_VERSION%%(*}; bash 4+ is now at $NEW_BASH"
    fi
  fi
  have git && set_status git ok "$(git --version 2>/dev/null | awk '{print $3}')"
  have jq  && set_status jq  ok "$(jq --version 2>/dev/null)"
  PY=""
  for cand in "${RATCHET_PYTHON:-}" python3 python "py -3"; do
    [ -n "$cand" ] || continue
    if probe_py "$cand"; then PY="$cand"; break; fi
  done
  if [ -n "$PY" ] && [ "$(status_of python3)" != "wrong-world" ]; then
    set_status python3 ok "$($PY -c 'import sys;print(sys.version.split()[0])' 2>/dev/null) (via '$PY')"
  fi
  if have gh; then
    if gh auth status >/dev/null 2>&1; then
      set_status gh ok "$(gh --version 2>/dev/null | head -1 | awk '{print $3}') (authenticated)"
    else
      set_status gh unauth "installed, not logged in -- run: gh auth login"
    fi
  fi
  for d in $OPTIONAL_DEPS; do
    have "$d" && set_status "$d" ok "installed"
  done
fi

head1 "Status"
printf '  %-10s %-6s %-8s %s\n' "DEPENDENCY" "TIER" "STATUS" "DETAIL"
printf '  %-10s %-6s %-8s %s\n' "----------" "----" "------" "------"

FATAL_MISSING=0
report_row() { # report_row <dep> <tier>
  local dep="$1" tier="$2" st dt colour
  st="$(status_of "$dep")"
  dt="$(detail_of "$dep")"
  [ -n "$st" ] || { st="-"; dt="not checked"; }
  case "$st" in
    ok)          colour="$C_G" ;;
    unauth|old)  colour="$C_Y" ;;
    *)           if [ "$tier" = "FATAL" ]; then colour="$C_R"; else colour="$C_Y"; fi ;;
  esac
  if [ "$tier" = "FATAL" ] && [ "$st" != "ok" ]; then FATAL_MISSING=1; fi
  printf '  %-10s %-6s %s%-8s%s %s\n' "$dep" "$tier" "$colour" "$st" "$C_0" "$dt"
}

for d in $FATAL_DEPS; do report_row "$d" "FATAL"; done
for d in $WARN_DEPS;  do report_row "$d" "warn";  done
for d in $OPTIONAL_DEPS; do report_row "$d" "opt"; done

# A bash that is merely OLD while a good one sits on disk is not a missing
# dependency; it is a wrong command line. Do not fail the run for it, but do
# not let it read as "ok" either -- the row above already says 'old'.
if [ "$(status_of bash)" = "old" ]; then
  FATAL_MISSING=0
  for d in git jq python3; do
    case "$(status_of "$d")" in ok) ;; *) FATAL_MISSING=1 ;; esac
  done
fi

# =============================================================================
# SECTION 7 -- WHAT TO DO NEXT
# =============================================================================
head1 "Next"

if [ "$DRY_RUN" = "1" ]; then
  say "  --dry-run: nothing was changed. Re-run without it to install."
fi

if [ "$FATAL_MISSING" = "1" ]; then
  say "  One or more FATAL dependencies are still missing. install.sh will refuse,"
  say "  and that refusal is correct: a gate that cannot run has not passed."
  say "  Fix the red rows above, then run this script again to confirm."
  if [ "$IN_WSL" = "1" ]; then
    say ""
    say "  If any row says 'wrong-world', no package will fix it. Re-read the WSL"
    say "  section above and pick one side -- all-WSL or all-Windows."
  fi
  say ""
  exit 1
fi

case "$STACK" in
  none) NEXT_STACK="generic" ;;
  *)    NEXT_STACK="$STACK" ;;
esac

if [ "$(status_of bash)" = "old" ]; then
  BASH4="$(find_bash4 || true)"
  say "  Every FATAL dependency is present, but this shell is bash ${BASH_VERSION%%(*}."
  say "  Run the installer with the newer bash:"
  say ""
  say "      $BASH4 ./install.sh --target $TARGET_ARG --stack $NEXT_STACK"
else
  say "  Every FATAL dependency is present. Now run:"
  say ""
  if [ "$OS_KIND" = "windows" ]; then
    say "      ./install.sh --target $TARGET_ARG --stack $NEXT_STACK"
    say "  (or, from PowerShell:  .\\install.ps1 -Target $TARGET_ARG -Stack $NEXT_STACK)"
  else
    say "      ./install.sh --target $TARGET_ARG --stack $NEXT_STACK"
  fi
fi

if [ "$(status_of gh)" != "ok" ]; then
  say ""
  say "  Reminder: gh is not ready. Everything up to the Ship Prompt works, and"
  say "  then the run stops at the PR. Fix it before your first ship:  gh auth login"
fi

say ""
exit 0
