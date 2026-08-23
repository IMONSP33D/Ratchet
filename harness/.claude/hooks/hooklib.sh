#!/usr/bin/env bash
# hooklib.sh - shared helpers for every Ratchet hook (CONTRACT SS4). Prefix: rt_
# HUMANS: do not edit. This file is control-set / Tier 2b and never escalatable.
# ------------------------------------------------------------------------------------------------
# This is a SOURCED library. It sets no shell options (set -e/-u in a sourced file leaks into every
# caller) and is written to be safe under the caller's `set -uo pipefail`.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"
#
# Sourcing it also sources ratchet.config.sh (which resolves REPO_ROOT, cds there, and loads the
# domain + stack packs). Both are idempotent.
#
# Every function here is called by name from other builders' scripts. Signatures are frozen by
# CONTRACT SS4; the extras below the fold are additions, not redefinitions.
#
# STATE FILES THIS LIBRARY WRITES (reader and writer change together, CONTRACT SS0.7):
#   $PIPELINE_DIR/.py-interp   one line per host: "<host><TAB><python command>". rt_pick_py owns it.
#   $RUN_LAST_SEEN             one line: epoch seconds of the last hook firing. rt_touch_seen owns it.
#   $RUN_IDLE                  one line: accumulated idle seconds (integer). rt_touch_seen owns it.
#   $CMD_LOG                   one TAB-separated line per guard decision; see rt_log_cmd.
#   $EVENTS_LOG                one JSON object per line (CONTRACT SS7.9); see rt_event.
# NOTE: nothing here ever writes $RUN_START. Editing RUN_START would silently clear a budget halt,
# which is exactly the failure the work-time budget exists to prevent (CONTRACT SS5.3).
# ------------------------------------------------------------------------------------------------

if [ -n "${RATCHET_HOOKLIB_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
RATCHET_HOOKLIB_LOADED=1

_rt_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -z "${RATCHET_CONFIG_LOADED:-}" ]; then
  # shellcheck source=ratchet.config.sh disable=SC1090,SC1091
  . "$_rt_lib_dir/ratchet.config.sh"
fi
HOOKS_DIR="${HOOKS_DIR:-$_rt_lib_dir}"

# =================================================================================================
# 0. tiny primitives
# =================================================================================================

rt_warn() { printf 'ratchet: %s\n' "$*" >&2; }
rt_now()  { date +%s 2>/dev/null || printf '0'; }
rt_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
rt_have_jq() { command -v jq >/dev/null 2>&1; }
rt_host() {
  local h="${HOSTNAME:-}"
  [ -n "$h" ] || h=$(hostname 2>/dev/null)
  [ -n "$h" ] || h=$(uname -n 2>/dev/null)
  printf '%s' "${h:-unknown-host}"
}
rt_mkdirp() { [ -d "${1:-}" ] || mkdir -p "${1:-}" 2>/dev/null || return 1; }

# Trim leading/trailing whitespace and CR, in pure bash (no subprocess: Git-Bash forks are slow
# and these run in tight loops).
rt_trim() {
  local s="${1-}"
  s=${s//$'\r'/}
  while :; do case "$s" in ' '*|$'\t'*) s=${s#?} ;; *) break ;; esac; done
  while :; do case "$s" in *' '|*$'\t') s=${s%?} ;; *) break ;; esac; done
  printf '%s' "$s"
}

# bash 4 lowercasing - no `tr` fork, because these run in tight loops on a host where forking is
# the single most expensive thing a hook does.
rt_lc() { local s="${1-}"; printf '%s' "${s,,}"; }

# JSON string escaping for the small objects we emit by hand.
rt_json_escape() {
  local s="${1-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# sha256 of a string / a file. Returns 1 when no digest tool exists at all - callers that need a
# digest for an approval check MUST treat that as "no approval" and refuse (fail closed).
rt_sha256_str() {
  local s="${1-}" py
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$s" | openssl dgst -sha256 2>/dev/null | sed 's/.*= *//'
  else
    py=$(rt_pick_py) || return 1
    # shellcheck disable=SC2086
    printf '%s' "$s" | $py -c 'import sys,hashlib;sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null
  fi
}
rt_sha256_file() {
  local f="${1-}" py
  [ -f "$f" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$f" 2>/dev/null | sed 's/.*= *//'
  else py=$(rt_pick_py) || return 1
    # shellcheck disable=SC2086
    $py -c 'import sys,hashlib;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f" 2>/dev/null
  fi
}

# =================================================================================================
# 1. repo root + interpreter probe   (CONTRACT SS4.1)
# =================================================================================================

# rt_repo_root - resolve, cd, echo. ratchet.config.sh already did this at source time; this is the
# callable form other builders use.
rt_repo_root() {
  if [ -n "${REPO_ROOT:-}" ] && [ -d "$REPO_ROOT" ]; then
    cd "$REPO_ROOT" 2>/dev/null || return 1
    printf '%s\n' "$REPO_ROOT"
    return 0
  fi
  local d
  if command -v git >/dev/null 2>&1; then
    d=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$d" ]; then REPO_ROOT="$d"; cd "$d" || return 1; printf '%s\n' "$d"; return 0; fi
  fi
  REPO_ROOT="$PWD"; printf '%s\n' "$PWD"
}

# rt_pick_py - first working python3. Tries $RATCHET_PYTHON, python3, python, "py -3" in order and
# accepts a candidate only if `<cand> -c "import sys;print(sys.version_info[0])"` prints exactly 3.
# The Windows Store python stub is on PATH as `python3` on many Windows hosts, exits non-zero and
# prints nothing - skipping it is the entire reason this probe exists.
# The winner is cached in $PIPELINE_DIR/.py-interp as "<host><TAB><command>" (one line per host, so
# a repo synced between a Windows box and WSL does not poison the other's cache).
# Echoes a COMMAND STRING which may contain a space ("py -3"); callers must invoke it UNQUOTED.
rt_pick_py() {
  local cache="${PIPELINE_DIR:-.pipeline}/.py-interp" host h c cand out tmp
  host=$(rt_host)
  # Cache read is pure bash (no fork) - this runs on every hook firing.
  if [ -f "$cache" ]; then
    while IFS=$'\t' read -r h c; do
      h=${h//$'\r'/}; c=${c//$'\r'/}
      if [ "$h" = "$host" ] && [ -n "$c" ] && command -v "${c%% *}" >/dev/null 2>&1; then
        printf '%s\n' "$c"; return 0
      fi
    done < "$cache"
  fi
  for cand in ${RATCHET_PYTHON:+"$RATCHET_PYTHON"} python3 python "py -3"; do
    command -v "${cand%% *}" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2086
    out=$($cand -c "import sys;print(sys.version_info[0])" 2>/dev/null)
    out=${out%$'\r'}
    [ "$out" = "3" ] || continue
    if rt_mkdirp "${PIPELINE_DIR:-.pipeline}"; then
      tmp="$cache.$$"
      { [ -f "$cache" ] && tr -d '\r' < "$cache" | grep -v -F "${host}"$'\t'; } > "$tmp" 2>/dev/null
      printf '%s\t%s\n' "$host" "$cand" >> "$tmp" 2>/dev/null
      mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
    printf '%s\n' "$cand"; return 0
  done
  return 1
}

# =================================================================================================
# 2. hook payload access
# =================================================================================================

# rt_payload - the hook's stdin JSON, read once and cached. Safe to call many times.
# CALL IT FIRST IN THE HOOK'S OWN SHELL: `rt_payload >/dev/null`. Reaching for it as
# `X=$(rt_payload)` reads stdin inside a subshell, the cache dies with that subshell, and every
# later field read finds stdin already consumed - which fails closed (the guard blocks everything)
# but for a reason that has nothing to do with the command.
rt_payload() {
  if [ -z "${RT_PAYLOAD_READ:-}" ]; then
    RT_PAYLOAD_READ=1
    RT_PAYLOAD=""
    if [ ! -t 0 ]; then RT_PAYLOAD=$(cat 2>/dev/null); fi
  fi
  printf '%s' "${RT_PAYLOAD:-}"
}

# rt_json_field <dotted.field> [json] - extract a string field from the payload.
# Order: jq (correct) > python json (correct) > sed (best-effort).
# The sed path is for NON-SECURITY fields only. A security decision that cannot be parsed must
# BLOCK - see guard.sh's ship-consent-unparsable rule, which requires jq outright.
rt_json_field() {
  local field="${1-}" json="${2-}" py val
  [ -n "$json" ] || json=$(rt_payload)
  [ -n "$json" ] || return 1
  if rt_have_jq; then
    val=$(printf '%s' "$json" | jq -r --arg f "$field" '
        reduce ($f|split(".")[]) as $k (.; if type=="object" then .[$k] else null end)
        | if . == null then empty elif type=="string" then . else tojson end' 2>/dev/null)
    [ -n "$val" ] || return 1
    printf '%s' "$val"; return 0
  fi
  py=$(rt_pick_py)
  if [ -n "$py" ]; then
    # shellcheck disable=SC2086
    val=$(printf '%s' "$json" | $py -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
cur = d
for k in sys.argv[1].split("."):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(1)
if cur is None:
    sys.exit(1)
sys.stdout.write(cur if isinstance(cur, str) else json.dumps(cur))
' "$field" 2>/dev/null)
    if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
    return 1
  fi
  # Last resort: grab "<lastkey>": "<value>" with minimal escape handling.
  local key="${field##*.}"
  val=$(printf '%s' "$json" \
        | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\\\]\|\\\\.\)*\)\".*/\1/p" \
        | head -n 1)
  [ -n "$val" ] || return 1
  # unescape the few sequences that matter for a command line
  val=${val//\\n/$'\n'}
  val=${val//\\t/$'\t'}
  val=${val//\\\"/\"}
  val=${val//\\\\/\\}
  printf '%s' "$val"
}

# =================================================================================================
# 3. the two-view command parser
# =================================================================================================
# A Bash command must be read twice, for two different questions:
#
#   STRUCTURAL VIEW (rt_strip_data) - "what does the shell DO?" Quoted material is removed, so a
#     `>` or `&&` inside a string cannot masquerade as an operator and, conversely, an operator
#     cannot hide inside quotes.
#   TARGET VIEW (rt_strip_msg) - "what does this command TOUCH?" Only the prose payload of
#     -m/--message/--body/-F (and friends) is removed; every other quoted argument is kept, because
#     `rm '.context/SPEC.md'` is a real target and `git commit -m "delete .context/SPEC.md"` is not.
#
# Using one view for both questions is how a guard either blocks commit messages or misses
# redirects. Neither view is authoritative alone.
# -------------------------------------------------------------------------------------------------

# rt_tokenize <cmd> - one line per token: "<flag><TAB><value>".
#   flag P = the token contained no quoting or escapes (so it may be a shell operator)
#   flag Q = the token contained quoted or backslash-escaped material (it is data, never an operator)
#   value  = the token with quotes removed and backslash escapes applied
# Returns 1 on an unterminated quote. A caller that gets 1 MUST block: an unparsable command cannot
# be shown to be safe, and fail-closed is the rule (CONTRACT SS0.3).
rt_tokenize() {
  local s="${1-}" n i c q tok had started flag
  n=${#s}; i=0; q=''; tok=''; had=0; started=0
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=''
      elif [ "$c" = '\' ] && [ "$q" = '"' ]; then i=$((i+1)); tok="$tok${s:i:1}"
      else tok="$tok$c"; fi
    else
      case "$c" in
        "'"|'"') q="$c"; had=1; started=1 ;;
        '\')     i=$((i+1)); tok="$tok${s:i:1}"; had=1; started=1 ;;
        ' '|$'\t'|$'\n')
                 if [ "$started" = "1" ]; then
                   flag=P; [ "$had" = "1" ] && flag=Q
                   printf '%s\t%s\n' "$flag" "$tok"
                 fi
                 tok=''; had=0; started=0 ;;
        *)       tok="$tok$c"; started=1 ;;
      esac
    fi
    i=$((i+1))
  done
  [ -n "$q" ] && return 1
  if [ "$started" = "1" ]; then
    flag=P; [ "$had" = "1" ] && flag=Q
    printf '%s\t%s\n' "$flag" "$tok"
  fi
  return 0
}

# rt_strip_data <cmd> - STRUCTURAL VIEW. All quoted and backslash-escaped material removed.
rt_strip_data() {
  local s="${1-}" n i c q out
  n=${#s}; i=0; q=''; out=''
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=''
      elif [ "$c" = '\' ] && [ "$q" = '"' ]; then i=$((i+1)); fi
    else
      case "$c" in
        "'"|'"') q="$c" ;;
        '\')     i=$((i+1)) ;;
        *)       out="$out$c" ;;
      esac
    fi
    i=$((i+1))
  done
  printf '%s' "$out"
}

# rt_strip_msg <cmd> - TARGET VIEW. Drops the prose payload of message-carrying flags and keeps
# everything else, including other quoted arguments.
# DEVIATION worth knowing: the result is a NORMALISED reconstruction, not the original bytes -
# surviving tokens that were quoted are re-emitted single-quoted. Nothing downstream compares this
# view byte-for-byte (the escalation MAC hashes the ORIGINAL command, never a view); it exists only
# to be scanned for paths and tokens.
rt_strip_msg() {
  local cmd="${1-}" toks out="" flag val skip=0 esc
  toks=$(rt_tokenize "$cmd") || { printf '%s' "$cmd"; return 1; }
  while IFS=$'\t' read -r flag val; do
    [ -n "$flag" ] || continue
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    if [ "$flag" = "P" ]; then
      case "$val" in
        -m|--message|--body|-F|--body-file|--message-file|--title|--notes|--description)
          skip=1; continue ;;
        --message=*|--body=*|--title=*|--notes=*|--description=*)
          continue ;;
        -[a-zA-Z]*m)   # combined short flags whose last letter is m: -am, -sm, ...
          skip=1; continue ;;
      esac
    else
      case "$val" in
        -m*|--message=*|--body=*|--title=*) continue ;;   # inline attached form: -m"..."
      esac
    fi
    if [ "$flag" = "Q" ]; then
      esc=${val//\'/\'\\\'\'}
      out="${out:+$out }'$esc'"
    else
      out="${out:+$out }$val"
    fi
  done <<< "$toks"
  printf '%s' "$out"
}

# =================================================================================================
# 4. paths
# =================================================================================================

# C:/x -> /c/x  (Git-Bash reports both forms depending on who produced the path)
_rt_drive() {
  local p="${1-}" d
  case "$p" in
    [A-Za-z]:/*) d=${p%%:*}; printf '/%s%s' "$(printf '%s' "$d" | tr 'A-Z' 'a-z')" "${p#*:}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# rt_repo_rel <path> - normalise to a repo-relative POSIX path.
# Strips CR, converts backslashes, folds a Windows drive prefix, removes the REPO_ROOT prefix,
# collapses "." and ".." lexically, and squeezes duplicate slashes. A path that genuinely escapes
# the repo keeps its leading ".." segments so it can never accidentally match a protected entry.
#
# rt_repo_rel_var is the same thing without the command substitution: it assigns the global RT_REL.
# Every in-library caller uses it, because `$(...)` forks a process and a guard normalises dozens of
# paths per invocation - on Git-Bash that is the difference between 40ms and a second.
rt_repo_rel() { rt_repo_rel_var "${1-}"; printf '%s' "$RT_REL"; }
rt_repo_rel_var() {
  local p="${1-}" root="${REPO_ROOT:-$PWD}" acc="" seg lead="" hadf=0
  p=${p//$'\r'/}
  p=${p//\\//}
  root=${root//\\//}
  # C:/x -> /c/x on both sides, so the two forms Git-Bash emits for the same path compare equal.
  # Was either side handed to us in Windows drive form, or are we on a Windows
  # shell at all? Either means the filesystem underneath is case-insensitive.
  RT_WINPATH=0
  case "$p"    in [A-Za-z]:/*) RT_WINPATH=1 ;; esac
  case "$root" in [A-Za-z]:/*) RT_WINPATH=1 ;; esac
  case "${OSTYPE:-}${MSYSTEM:-}" in *[Mm]sys*|*[Cc]ygwin*|*[Mm]ingw*) RT_WINPATH=1 ;; esac
  case "$p"    in [A-Za-z]:/*) seg=${p%%:*};    p="/${seg,,}${p#*:}" ;; esac
  case "$root" in [A-Za-z]:/*) seg=${root%%:*}; root="/${seg,,}${root#*:}" ;; esac
  while [ "$p" != "${p//\/\//\/}" ]; do p=${p//\/\//\/}; done
  case "$p" in
    "$root"/*) p=${p#"$root"/} ;;
    "$root")   p="." ;;
    *)
      # Windows filesystems are CASE-INSENSITIVE, and the four sources of a path
      # here -- CLAUDE_PROJECT_DIR, git rev-parse, BASH_SOURCE, and the tool
      # payload -- do not agree on casing for the same directory. When they
      # disagreed, the prefix strip silently failed, the path stayed ABSOLUTE,
      # and every downstream comparison misfired: .pipeline/ stopped matching its
      # own exemption, so the agent was refused its own scratch directory.
      # Compare case-insensitively on Windows-ish paths ONLY -- POSIX paths are
      # genuinely case-sensitive and must keep comparing exactly. The slice is
      # taken from the ORIGINAL string, so the real casing survives.
      if [ "${RT_WINPATH:-0}" = "1" ]; then
        local lp lr
        lp=${p,,}; lr=${root,,}
        case "$lp" in
          "$lr"/*) p=${p:$(( ${#root} + 1 ))} ;;
          "$lr")   p="." ;;
        esac
      fi ;;
  esac
  case "$p" in /*) lead="/" ;; esac
  case $- in *f*) hadf=1 ;; esac
  set -f
  local oldifs="$IFS"; IFS=/
  # shellcheck disable=SC2086
  set -- $p
  IFS="$oldifs"
  [ "$hadf" = "0" ] && set +f
  for seg in "$@"; do
    case "$seg" in
      ''|.) continue ;;
      ..)
        if [ -n "$acc" ] && [ "${acc##*/}" != ".." ]; then
          case "$acc" in */*) acc=${acc%/*} ;; *) acc="" ;; esac
        elif [ -n "$lead" ]; then
          :   # /.. is /
        else
          acc="${acc:+$acc/}.."
        fi ;;
      *) acc="${acc:+$acc/}$seg" ;;
    esac
  done
  if [ -z "$acc" ] && [ -z "$lead" ]; then RT_REL="."; else RT_REL="${lead}${acc}"; fi
  return 0
}
RT_REL=""

# rt_path_matches_list <path> <newline-separated entries>
# Entry forms (CONTRACT-free, documented in domain.config.sh):
#   exact path        .context/SPEC.md
#   directory prefix  secrets/          (trailing slash)
#   bare filename     LIVE_CONFIRMED    (basename match anywhere)
#   glob              *.pem  .env.*  id_rsa*   (matched against both full path and basename)
# NOTE: bash `case` globbing lets `*` cross `/`, so `src/*` matches `src/a/b.py`. That is
# deliberately permissive: for a DENY list, over-matching is the safe direction.
rt_path_matches_list() {
  local p base e fold=0
  [ -n "${2-}" ] || return 1
  rt_repo_rel_var "${1-}"; p="$RT_REL"
  base=${p##*/}
  # On a case-insensitive mount (Windows), a case-variant path denotes the SAME
  # file, so a DENY / governing-corpus list MUST match case-insensitively -- or
  # every rule that runs through here (secrets, corpus, control set, forbidden
  # artifacts) is bypassed by flipping one letter's case, and a control-set file
  # written as `Guard.sh` even downgrades to the confirmable claude-dir rule.
  # Over-matching a deny list is the safe direction. Allow-side matchers
  # (partition globs, manifest) deliberately stay case-sensitive: over-matching
  # THOSE would WIDEN writes, which is the unsafe direction.
  [ "${RT_WINPATH:-0}" = "1" ] && fold=1
  if [ "$fold" = "1" ]; then p=${p,,}; base=${base,,}; fi
  while IFS= read -r e; do
    e=${e//$'\r'/}
    e=${e#"${e%%[![:space:]]*}"}
    e=${e%"${e##*[![:space:]]}"}
    [ -n "$e" ] || continue
    case "$e" in '#'*) continue ;; esac
    e=${e//\\//}
    [ "$fold" = "1" ] && e=${e,,}
    case "$e" in
      */)
        case "$p/" in "$e"*) return 0 ;; esac
        [ "$p" = "${e%/}" ] && return 0
        ;;
      *[*?[]*)
        # shellcheck disable=SC2254
        case "$p"    in $e) return 0 ;; esac
        # shellcheck disable=SC2254
        case "$base" in $e) return 0 ;; esac
        ;;
      */*)
        [ "$p" = "$e" ] && return 0
        case "$p/" in "$e/"*) return 0 ;; esac
        ;;
      *)
        [ "$base" = "$e" ] && return 0
        [ "$p" = "$e" ] && return 0
        ;;
    esac
  done <<< "$2"
  return 1
}

# rt_is_test_path <path> - via the STACK pack's TEST_PATH_REGEX.
rt_is_test_path() {
  local p
  [ -n "${TEST_PATH_REGEX:-}" ] || return 1
  rt_repo_rel_var "${1-}"; p="$RT_REL"
  printf '%s\n' "$p" | grep -Eq "$TEST_PATH_REGEX" 2>/dev/null
}

# rt_glob_match <path> <globs...> - partition-glob membership. Globs may be newline- or
# space-separated, in one argument or several.
# _rt_glob_re <glob> - pathspec glob -> ERE. * and ? are segment-local; ** crosses.
_rt_glob_re() {
  printf '%s' "${1-}" | awk '
    {
      n = length($0); out = ""
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "*") {
          if (substr($0, i + 1, 1) == "*") { out = out ".*"; i++ }
          else out = out "[^/]*"
        }
        else if (c == "?") out = out "[^/]"
        else if (index(".+()[]{}^$|\\", c) > 0) out = out "\\" c
        else out = out c
      }
      print out
    }'
}

rt_glob_match() {
  local p="${1-}" g rest
  shift 2>/dev/null || true
  rest="$*"
  [ -n "$rest" ] || return 1
  rt_repo_rel_var "$p"; p="$RT_REL"
  rest=${rest//$'\r'/}
  rest=${rest// /$'\n'}
  rest=${rest//$'\t'/$'\n'}
  while IFS= read -r g; do
    g=${g//$'\r'/}
    g=${g#"${g%%[![:space:]]*}"}
    g=${g%"${g##*[![:space:]]}"}
    [ -n "$g" ] || continue
    case "$g" in '#'*) continue ;; esac
    g=${g//\\//}
    while :; do case "$g" in ./*) g=${g#./} ;; *) break ;; esac; done
    # Segment-aware match. Shell 'case' globbing lets * cross '/', so 'src/*.py'
    # would admit 'src/deep/a.py' and a partition glob would silently be wider
    # than the architect declared. Pathspec semantics: * and ? stay inside one
    # segment; ** crosses them.
    if printf '%s' "$p" | grep -Eq "^$(_rt_glob_re "$g")\$" 2>/dev/null; then return 0; fi
    case "$g" in
      */) case "$p/" in "$g"*) return 0 ;; esac ;;
    esac
    # "src/foo" as a glob also admits everything beneath it
    case "$p/" in "$g/"*) return 0 ;; esac
  done <<< "$rest"
  return 1
}

# =================================================================================================
# 5. manifest  (CONTRACT SS7.6 - ONE parser, shared by the Stop gate and check_done.py)
# =================================================================================================
# PLAN_FILES : one repo-relative path per line; blank lines and #-comments ignored.
# AMENDMENTS : "<path> <DEC-id> [note]" - the DEC id is MANDATORY. A line without a well-formed
#              DEC id is malformed and grants NO scope (it is reported, not silently honoured):
#              an amendment nobody logged a decision for is exactly what the manifest exists to
#              catch.

rt_amend_paths() {
  local line pth dec hadf=0
  [ -f "${AMENDMENTS:-}" ] || return 0
  case $- in *f*) hadf=1 ;; esac
  set -f
  while IFS= read -r line; do
    line=$(rt_trim "$line")
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    pth="${1:-}"; dec="${2:-}"
    case "$dec" in
      DEC-[0-9]*) ;;
      *) rt_warn "manifest-amendment ignored (no DEC id): $line"; continue ;;
    esac
    [ -n "$pth" ] && rt_repo_rel "$pth" && printf '\n'
  done < "$AMENDMENTS"
  [ "$hadf" = "0" ] && set +f
  return 0
}

rt_manifest_paths() {
  local line
  if [ -f "${PLAN_FILES:-}" ]; then
    while IFS= read -r line; do
      line=$(rt_trim "$line")
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      rt_repo_rel "$line"; printf '\n'
    done < "$PLAN_FILES"
  fi
  rt_amend_paths
}

# rt_in_manifest <path> - membership, tolerant of normalisation and of directory entries.
rt_in_manifest() {
  local p e
  rt_repo_rel_var "${1-}"; p="$RT_REL"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$p" = "$e" ] && return 0
    case "$e" in
      */) case "$p/" in "$e"*) return 0 ;; esac ;;
      *[*?[]*)
        # shellcheck disable=SC2254
        case "$p" in $e) return 0 ;; esac ;;
    esac
    case "$p/" in "$e/"*) return 0 ;; esac
  done <<< "$(rt_manifest_paths)"
  return 1
}

# =================================================================================================
# 6. attribution  (CONTRACT SS5.4)
# =================================================================================================
# Three named modes, degrading loudly. The env vars PIPELINE_DISPATCH_ID / PIPELINE_PARTITION_GLOB
# do NOT reliably reach hook environments from the Agent tool (measured), so the orchestrator
# writes them to disk and hooks read the FILES first:
#     $DISPATCH_DIR/current        the id of the dispatch in flight
#     $DISPATCH_DIR/<id>.glob      that dispatch's write allow-list (one glob per line)
#     $DISPATCH_DIR/<id>.baseline  tree snapshot from dispatch-baseline.sh (enables exact mode)
# ".tree" and ".files" are accepted as baseline names too, since dispatch-baseline.sh is owned by
# another builder; the FIRST that exists wins.

rt_dispatch_id() {
  local id=""
  if [ -f "${DISPATCH_DIR:-.pipeline/dispatch}/current" ]; then
    id=$(tr -d '\r' < "${DISPATCH_DIR:-.pipeline/dispatch}/current" 2>/dev/null | head -n 1)
    id=$(rt_trim "$id")
  fi
  [ -n "$id" ] || id="${PIPELINE_DISPATCH_ID:-}"
  printf '%s' "$id"
}

rt_dispatch_glob() {
  local id="${1:-$(rt_dispatch_id)}" f
  if [ -n "$id" ]; then
    f="${DISPATCH_DIR:-.pipeline/dispatch}/${id}.glob"
    if [ -f "$f" ]; then tr -d '\r' < "$f" 2>/dev/null; return 0; fi
  fi
  if [ -n "${PIPELINE_PARTITION_GLOB:-}" ]; then
    printf '%s\n' "${PIPELINE_PARTITION_GLOB}"; return 0
  fi
  return 1
}

rt_dispatch_baseline() {
  local id="${1:-$(rt_dispatch_id)}" d="${DISPATCH_DIR:-.pipeline/dispatch}" ext
  [ -n "$id" ] || return 1
  for ext in baseline tree files; do
    [ -f "$d/$id.$ext" ] && { printf '%s' "$d/$id.$ext"; return 0; }
  done
  return 1
}

# rt_attributable <path>
#   stdout : the mode name - exact | sound | weak
#   stderr : in every mode below exact, the REPORT-ONLY notice
#   exit 0 : the path may be this dispatch's work
#   exit 1 : the path is provably NOT this dispatch's work
#   exit 2 : undecidable (weak mode)
# The exit codes matter more than they look. In any mode below exact a gate may only REPORT an
# out-of-scope file. It must NEVER order a revert: the gate that did was handed pre-existing,
# human-owned changes as an agent's own and instructed the agent to destroy them, which the agent
# correctly refused because reverting them would itself have been a Tier 2b violation.
rt_attributable() {
  local p base globs rc
  rt_repo_rel_var "${1-}"; p="$RT_REL"
  base=$(rt_dispatch_baseline) && {
    printf 'exact'
    if grep -Fqx -- "$p" "$base" 2>/dev/null; then return 0; fi
    return 1
  }
  if globs=$(rt_dispatch_glob) && [ -n "$globs" ]; then
    printf 'sound'
    rt_warn "attribution mode=sound - a path outside the partition glob is provably not this agent's. REPORT ONLY; never order a revert."
    if rt_glob_match "$p" "$globs"; then return 0; fi
    return 1
  fi
  printf 'weak'
  rt_warn "attribution mode=WEAK - no dispatch baseline and no partition glob on disk. Attribution is a guess. REPORT ONLY; never order a revert."
  rc=2
  if rt_is_forbidden_path "$p"; then rc=1; fi   # the agent could not have written it
  return $rc
}

# The forbidden-path filter used by weak-mode attribution and by both guards.
rt_is_forbidden_path() {
  local p; rt_repo_rel_var "${1-}"; p="$RT_REL"
  rt_is_secret_path "$p" && return 0
  rt_path_matches_list "$p" "${GOVERNING_CORPUS:-}" && return 0
  rt_is_control_set "$p" && return 0
  rt_path_matches_list "$p" "${FORBIDDEN_ARTIFACTS:-}" && return 0
  return 1
}

rt_is_secret_path() {
  local p; rt_repo_rel_var "${1-}"; p="$RT_REL"
  rt_path_matches_list "$p" "${SECRET_EXEMPTIONS:-}" && return 1
  rt_path_matches_list "$p" "${SECRET_PATTERNS:-}" && return 0
  case "$p/" in "${SECRETS_DIR:-secrets}/"*) return 0 ;; esac
  return 1
}

# Control set is matched only under $CLAUDE_DIR so an unrelated settings.json is not swept up.
rt_is_control_set() {
  local p base; rt_repo_rel_var "${1-}"; p="$RT_REL"; base=${p##*/}
  case "$p/" in "${CLAUDE_DIR:-.claude}/"*) ;; *) return 1 ;; esac
  rt_path_matches_list "$base" "${CONTROL_SET:-}"
}

# =================================================================================================
# 7. run lifecycle + budget  (CONTRACT SS5.1, SS5.3)
# =================================================================================================

rt_run_active() { [ -s "${RUN_ACTIVE:-}" ]; }
rt_run_milestone() {
  [ -s "${RUN_ACTIVE:-}" ] || return 1
  rt_trim "$(tr -d '\r' < "$RUN_ACTIVE" 2>/dev/null | head -n 1)"
}

_rt_read_int() {
  local f="${1-}" v
  [ -f "$f" ] || { printf '0'; return 0; }
  v=$(tr -d '\r' < "$f" 2>/dev/null | head -n 1)
  v=$(rt_trim "$v")
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# rt_touch_seen - update RUN_LAST_SEEN and fold an idle gap into RUN_IDLE.
# Called on every hook firing. No-op when no run is active (nothing to budget).
rt_touch_seen() {
  rt_run_active || return 0
  local now last gap idle
  now=$(rt_now)
  last=$(_rt_read_int "${RUN_LAST_SEEN:-}")
  if [ "$last" -gt 0 ] 2>/dev/null; then
    gap=$(( now - last ))
    if [ "$gap" -gt "${IDLE_THRESHOLD_SECONDS:-900}" ]; then
      idle=$(_rt_read_int "${RUN_IDLE:-}")
      printf '%s\n' "$(( idle + gap ))" > "${RUN_IDLE}" 2>/dev/null || :
    fi
  fi
  rt_mkdirp "${PIPELINE_DIR:-.pipeline}" || return 0
  printf '%s\n' "$now" > "${RUN_LAST_SEEN}" 2>/dev/null || :
  return 0
}

# rt_wall_seconds / rt_work_seconds - work = wall - idle. Prints 0 when no run has started.
# NOTHING may edit RUN_START to clear a budget halt (CONTRACT SS5.3). If the budget is wrong, the
# budget is the thing to change - in config, in the open, once.
rt_wall_seconds() {
  local start now
  start=$(_rt_read_int "${RUN_START:-}")
  [ "$start" -gt 0 ] 2>/dev/null || { printf '0'; return 0; }
  now=$(rt_now)
  printf '%s' "$(( now - start ))"
}
rt_work_seconds() {
  local wall idle w
  wall=$(rt_wall_seconds)
  idle=$(_rt_read_int "${RUN_IDLE:-}")
  w=$(( wall - idle ))
  [ "$w" -lt 0 ] && w=0
  printf '%s' "$w"
}

# =================================================================================================
# 8. blocking + logging
# =================================================================================================

# rt_block <msg> - PreToolUse refusal: reason on stderr, exit 2.
rt_block() {
  printf '%s\n' "${1-blocked}" >&2
  exit 2
}

# rt_block_json <msg> - Stop/SubagentStop refusal: decision JSON on stdout, exit 0.
rt_block_json() {
  printf '{"decision":"block","reason":"%s"}\n' "$(rt_json_escape "${1-blocked}")"
  exit 0
}

# rt_event <type> <k=v...> - append to the events log. Prefers pipeline-event.sh (which owns the
# schema); falls back to writing the CONTRACT SS7.9 object directly so an event is never lost just
# because the helper is absent. Never fails a hook.
rt_event() {
  local t="${1-event}" kv k v json ms arg
  shift 2>/dev/null || true
  if [ -x "${HOOKS_DIR:-}/pipeline-event.sh" ]; then
    "${HOOKS_DIR}/pipeline-event.sh" "$t" "$@" >/dev/null 2>&1 || :
    return 0
  fi
  rt_mkdirp "${PIPELINE_DIR:-.pipeline}" || return 0
  kv=""
  for arg in "$@"; do
    k=${arg%%=*}; v=${arg#*=}
    [ "$k" = "$arg" ] && v=""
    kv="${kv:+$kv,}\"$(rt_json_escape "$k")\":\"$(rt_json_escape "$v")\""
  done
  ms=$(rt_run_milestone 2>/dev/null || printf '')
  json="{\"ts\":\"$(rt_iso)\",\"type\":\"$(rt_json_escape "$t")\",\"run\":\"$(rt_json_escape "${RATCHET_RUN_TOKEN:-}")\",\"milestone\":\"$(rt_json_escape "$ms")\",\"kv\":{${kv}}}"
  printf '%s\n' "$json" >> "${EVENTS_LOG}" 2>/dev/null || :
  return 0
}

# rt_log_cmd <tool> <decision> <rule> <sha> <text> - one line per guard decision.
# FORMAT (TAB separated, one line, never rewritten):
#   <iso8601-utc> <tool> <ALLOW|BLOCK|ALLOW-APPROVED> <rule-id or -> <sha256[0:12] or -> <text>
# <text> has CR/LF/TAB replaced by spaces and is truncated to 400 characters. The log is an audit
# trail, not a transcript: it must stay greppable line-per-decision.
rt_log_cmd() {
  local tool="${1-}" decision="${2-}" rule="${3--}" sha="${4--}" text="${5-}"
  rt_mkdirp "${PIPELINE_DIR:-.pipeline}" || return 0
  text=${text//$'\r'/ }
  text=${text//$'\n'/ }
  text=${text//$'\t'/ }
  [ ${#text} -gt 400 ] && text="${text:0:400}..."
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(rt_iso)" "${tool:--}" "${decision:--}" "${rule:--}" "${sha:0:12}" "$text" \
    >> "${CMD_LOG}" 2>/dev/null || :
  return 0
}

# =================================================================================================
# 9. write-effect analysis   (CONTRACT SS0.4 - decide by EFFECT, never by verb token)
# =================================================================================================
# rt_write_targets <cmd> - every path the command would WRITE, one repo-relative path per line.
# Sources of a write effect, all of which must be considered BEFORE any "this is only a read
# command" carve-out:
#   redirects            > >> >| 1> 2> &> (spaced or attached)
#   copy/move/link       cp mv ln install rsync   -> POSIX last-argument target
#   in-place rewriters   sed -i, perl -i, ruby -i -> every file argument after the script
#   bulk writers         tee dd truncate touch mkdir patch chmod chown shred split
#   destructive          rm rmdir unlink
#   heredocs             the body is tokenised like any other text, so `patch <<EOF` diff headers
#                        are seen; a/ and b/ prefixes are stripped so b/.context/SPEC.md matches.
# It OVER-approximates on purpose. A false refusal costs one escalation; a missed write to the
# governing corpus costs the contract.
rt_write_targets() {
  local cmd="${1-}" toks flag val n k v f nxt verb_class="" seen_script=0 patchy=0
  toks=$(rt_tokenize "$cmd") || return 1
  local -a F=() V=()
  while IFS=$'\t' read -r flag val; do
    [ -n "$flag" ] || continue
    F[${#F[@]}]="$flag"; V[${#V[@]}]="$val"
  done <<< "$toks"
  n=${#V[@]}
  k=0
  # pass 1: redirect targets
  while [ "$k" -lt "$n" ]; do
    v=${V[$k]}; f=${F[$k]}
    if [ "$f" = "P" ]; then
      case "$v" in
        '>'|'>>'|'>|'|'1>'|'2>'|'&>'|'1>>'|'2>>'|'&>>'|'>&')
          nxt=$((k+1))
          if [ "$nxt" -lt "$n" ]; then
            case "${V[$nxt]}" in
              /dev/*|'&1'|'&2'|1|2) ;;
              *) rt_repo_rel "${V[$nxt]}"; printf '\n' ;;
            esac
          fi
          k=$((nxt+1)); continue ;;
        '>'*|'>>'*|'1>'*|'2>'*|'&>'*)
          v=${v##*>}
          case "$v" in
            ''|/dev/*|'&1'|'&2') ;;
            *) rt_repo_rel "$v"; printf '\n' ;;
          esac
          ;;
      esac
    fi
    k=$((k+1))
  done
  # pass 2: write verbs
  k=0
  while [ "$k" -lt "$n" ]; do
    v=${V[$k]}; f=${F[$k]}
    if [ "$f" = "P" ] && [ -z "$verb_class" ]; then
      case "${v##*/}" in
        cp|mv|ln|install|rsync)          verb_class="last" ;;
        tee|dd|truncate|touch|mkdir|chmod|chown|shred|split|rm|rmdir|unlink)
                                          verb_class="all" ;;
        patch)                            verb_class="all"; patchy=1 ;;
        sed|perl|ruby)
          # only in-place invocations write
          local _t
          for _t in ${V[@]+"${V[@]}"}; do
            case "$_t" in -i|-i.*|-[a-zA-Z]*i|-[a-zA-Z]*i.*|--in-place|--in-place=*)
              verb_class="script-then-all"; break ;; esac
          done ;;
        git)
          nxt=$((k+1))
          if [ "$nxt" -lt "$n" ] && [ "${V[$nxt]}" = "apply" ]; then verb_class="all"; patchy=1; fi ;;
      esac
      if [ -n "$verb_class" ]; then
        # collect from here to the end (over-approximating across compound forms on purpose)
        local j=$((k+1)) last="" lastf="" t
        while [ "$j" -lt "$n" ]; do
          t=${V[$j]}
          case "$t" in
            -*) j=$((j+1)); continue ;;
            '>'*|'>>'*|'<'*|'|'|'&&'|'||'|';') j=$((j+1)); continue ;;
          esac
          case "$t" in *=*)
            case "${t%%=*}" in of|OF) rt_repo_rel "${t#*=}"; printf '\n' ;; esac
          ;; esac
          if [ "$verb_class" = "script-then-all" ] && [ "$seen_script" = "0" ]; then
            seen_script=1; j=$((j+1)); continue
          fi
          if [ "$verb_class" = "last" ]; then
            last="$t"; lastf="1"
          else
            if [ "$patchy" = "1" ]; then
              case "$t" in a/*|b/*) rt_repo_rel "${t#?/}"; printf '\n' ;; esac
            fi
            rt_repo_rel "$t"; printf '\n'
          fi
          j=$((j+1))
        done
        if [ "$verb_class" = "last" ] && [ -n "$lastf" ]; then rt_repo_rel "$last"; printf '\n'; fi
      fi
    fi
    k=$((k+1))
  done
  return 0
}

# rt_has_write_effect <cmd>
rt_has_write_effect() {
  local cmd="${1-}" structural
  structural=$(rt_strip_data "$cmd")
  case "$structural" in *'>'*) return 0 ;; esac
  [ -n "$(rt_write_targets "$cmd")" ] && return 0
  return 1
}

# rt_cmd_tokens <cmd> - every token VALUE of the TARGET VIEW, one per line (path candidates).
rt_cmd_tokens() {
  local flag val
  while IFS=$'\t' read -r flag val; do
    [ -n "$flag" ] || continue
    printf '%s\n' "$val"
    case "$val" in
      *=*) printf '%s\n' "${val#*=}" ;;
    esac
  done <<< "$(rt_tokenize "$(rt_strip_msg "${1-}")")"
}

# =================================================================================================
# 10. naming doctrine  (CONTRACT SS6)
# =================================================================================================
# rt_name_valid <name> - exit 0 valid, 1 invalid (reason on stderr).
# The one implementation of the naming rules as of 2026-08-23 (previously mirrored in a second,
# independent Python implementation, check_narrative.py --validate-name; that script was cut, and
# with it the shared-fixture parity test that kept the two in agreement):
#   * ^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$   (kebab-case, 2-5 words)
#   * not on the too-generic hard list
#   * not matching ^(fix|update|change|misc|various|general|temp|new|old)-
#   * multi-step form "<valid-name>-<n>" is accepted even when the counter pushes it past 5 words
# A name must state the problem: gate-blames-wrong-actor, not issue-3.
#
# ONE INTERPRETATION CALL: a name whose LAST segment is purely numeric is read as the multi-step
# form, so its base must itself be a valid name. That rejects `issue-3` and `phase-2` (base is one
# word) while accepting `harness-adjustment-1`. Read the other way - "issue-3 satisfies the 2-5 word
# regex, ship it" - the doctrine's own counter-example passes its own validator, which cannot be the
# intent. Names whose last word merely contains digits (`sha256-mismatch`) are unaffected.
RT_GENERIC_NAMES="fix-issue
fix-bug
misc-problem
update-thing
general-fix
various-fixes
minor-issue
small-fix
quick-fix
todo-item"

_rt_name_core_valid() {
  local n="${1-}"
  printf '%s' "$n" | grep -Eq '^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$' 2>/dev/null || return 1
  printf '%s' "$n" | grep -Eq '^(fix|update|change|misc|various|general|temp|new|old)-' 2>/dev/null && return 1
  local g
  while IFS= read -r g; do
    g=$(rt_trim "$g"); [ -n "$g" ] || continue
    [ "$n" = "$g" ] && return 1
  done <<< "$RT_GENERIC_NAMES"
  return 0
}

rt_name_valid() {
  local n base tail
  n=$(rt_trim "${1-}")
  if [ -z "$n" ]; then rt_warn "name-invalid: empty"; return 1; fi
  tail=${n##*-}
  case "$n" in
    *-*)
      case "$tail" in
        ''|*[!0-9]*) ;;                       # last word is not a bare number: ordinary name
        *)                                    # multi-step form: the BASE carries the meaning
          base=${n%-*}
          if _rt_name_core_valid "$base"; then return 0; fi
          rt_warn "name-invalid: '$n' is the multi-step form <name>-<n>, but its base '$base' is not a valid name - the base must state the problem (harness-adjustment-1, not issue-3)"
          return 1 ;;
      esac ;;
  esac
  if _rt_name_core_valid "$n"; then return 0; fi
  # report the most useful reason
  if printf '%s' "$n" | grep -Eq '^(fix|update|change|misc|various|general|temp|new|old)-' 2>/dev/null; then
    rt_warn "name-invalid: '$n' starts with a placeholder verb - name the PROBLEM, e.g. gate-blames-wrong-actor"
  elif printf '%s' "$n" | grep -Eq '^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$' 2>/dev/null; then
    rt_warn "name-invalid: '$n' is on the too-generic reject list"
  else
    rt_warn "name-invalid: '$n' must be kebab-case, 2-5 words: ^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}\$ (or that plus a -<n> step counter)"
  fi
  return 1
}

# =================================================================================================
# 11. stack rebinding
# =================================================================================================
# The stack pack may need the probed interpreter, which only exists after rt_pick_py is defined.
# A pack that cares defines stack_rebind(); every shipped pack defines it (generic's is a no-op).
if [ -z "${RT_PY:-}" ] && [ "${RATCHET_SKIP_PY_PROBE:-0}" != "1" ]; then
  RT_PY="$(rt_pick_py 2>/dev/null)" || RT_PY=""
fi
export RT_PY
if [ -n "${RT_PY:-}" ] && declare -F stack_rebind >/dev/null 2>&1; then
  stack_rebind
fi

# =================================================================================================
# 12. selftest
# =================================================================================================
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  _rt_fails=0
  _rt_ck() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; _rt_fails=$((_rt_fails+1)); fi
  }
  printf 'hooklib.sh selftest (repo_root=%s)\n' "${REPO_ROOT:-?}"

  _rt_ck "repo_rel ./a/../b"      "b"                 "$(rt_repo_rel './a/../b')"
  _rt_ck "repo_rel backslash+CR"  ".context/SPEC.md"  "$(rt_repo_rel $'.context\\SPEC.md\r')"
  _rt_ck "repo_rel escapes root"  "../x"              "$(rt_repo_rel '../x')"

  _rt_ck "strip_data hides quoted >" "echo  ; ls" "$(rt_strip_data 'echo "a > b" ; ls')"
  _rt_ck "strip_data keeps real >"   "cat x > y"  "$(rt_strip_data 'cat x > y')"

  _rt_ck "strip_msg drops -m prose"  "git commit"        "$(rt_strip_msg 'git commit -m "rm .env now"')"
  _rt_ck "strip_msg keeps quoted target" "rm '.env'"     "$(rt_strip_msg "rm '.env'")"

  _rt_ck "write_targets redirect" "protected.txt" "$(rt_write_targets 'cat a > protected.txt' | head -n1)"
  _rt_ck "write_targets cp last"  "b.txt"         "$(rt_write_targets 'cp a.txt b.txt' | tail -n1)"
  if rt_has_write_effect 'grep -r foo .context/SPEC.md'; then
    printf '  FAIL pure read flagged as write effect\n'; _rt_fails=$((_rt_fails+1))
  else printf '  ok   pure read has no write effect\n'; fi

  for _n in gate-blames-wrong-actor harness-adjustment-1 rate-limit-tightened; do
    rt_name_valid "$_n" 2>/dev/null || { printf '  FAIL name %s rejected\n' "$_n"; _rt_fails=$((_rt_fails+1)); }
  done
  for _n in fix-issue issue-3 FixThing fix-the-thing one various-fixes a-b-c-d-e-f; do
    if rt_name_valid "$_n" 2>/dev/null; then printf '  FAIL name %s accepted\n' "$_n"; _rt_fails=$((_rt_fails+1)); fi
  done
  printf '  ok   name validator (accept 3 / reject 7)\n'

  rt_path_matches_list "config/id_rsa.pub" "id_rsa*" || { printf '  FAIL glob list match\n'; _rt_fails=$((_rt_fails+1)); }
  rt_path_matches_list "docs/readme.md" "secrets/" && { printf '  FAIL false list match\n'; _rt_fails=$((_rt_fails+1)); }
  rt_glob_match "src/core/a.py" "src/core/*" || { printf '  FAIL glob_match\n'; _rt_fails=$((_rt_fails+1)); }
  rt_glob_match "tests/test_a.py" "src/core/*" && { printf '  FAIL glob_match false positive\n'; _rt_fails=$((_rt_fails+1)); }
  printf '  ok   path list + glob matching\n'

  if [ -n "${RT_PY:-}" ]; then printf '  ok   rt_pick_py -> %s\n' "$RT_PY"
  else printf '  note rt_pick_py found no python3 on this host (not fatal)\n'; fi

  if [ "$_rt_fails" -gt 0 ]; then printf 'hooklib selftest: %s FAILURE(S)\n' "$_rt_fails" >&2; exit 1; fi
  printf 'hooklib selftest: OK\n'
  exit 0
fi
