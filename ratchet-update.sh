#!/usr/bin/env bash
# =============================================================================
# ratchet-update.sh — mid-project updater for the RATCHET harness.
#
# THE PROBLEM THIS SOLVES
#   You installed Ratchet 1.0.0. You worked for six weeks. A newer scaffold
#   ships. You want the new control layer and you want to keep everything you
#   built: your domain pack, your SPEC and MILESTONES, your findings ledger,
#   your retro corpus, your decisions. Doing that by hand is a batched
#   multi-file edit to the control layer — precisely the operation the source
#   pipeline measured as self-harming (`batched-refinements-self-harm`).
#
# THE PROMISE
#   1. Every file is classified before anything is written, and the
#      classification is EXHAUSTIVE: a path this script does not recognise is
#      USER, and USER is never touched.
#   2. HARNESS files you (or an agent) edited locally are DETECTED, listed, and
#      preserved as `<file>.local-<timestamp>` — never silently clobbered. The
#      whole point of a control layer is that changes to it are deliberate.
#   3. The entire `.claude/` tree is backed up before a single byte is written,
#      and rollback is ONE command, printed on every path including success.
#   4. It refuses to run mid-run. Swapping the gates halfway means the run's
#      second half is judged by different rules than its first.
#   5. The file writing is done BY install.sh, not by a second implementation.
#      This script decides; install.sh writes. There is exactly one settings.json
#      merge in this codebase and it lives in install.sh.
#
# Usage:
#   ./ratchet-update.sh --check  --target ../my-repo --from /path/to/ratchet-1.1.0
#   ./ratchet-update.sh --apply  --target ../my-repo --from ./bundle.zip --yes
#   ./ratchet-update.sh --apply  --target ../my-repo --dry-run
#   ./ratchet-update.sh --adopt-baseline --target ../my-repo
#
# Options:
#   --check                     (DEFAULT) report what WOULD change; write nothing
#   --apply                     perform the update
#   --from <path>               bundle directory or .zip     (default: my own dir)
#   --target <repo>             repo to update               (default: cwd)
#   --dry-run                   rehearse --apply; write nothing
#   --yes                       do not prompt for confirmation
#   --force                     update even though a run is active (see §RUN)
#   --force-overwrite-modified  overwrite locally-modified HARNESS files with no
#                               .local-* copy kept (the backup still has them)
#   --allow-downgrade           permit installing an OLDER version
#   --adopt-baseline            write .claude/.ratchet-manifest from the CURRENT
#                               on-disk state and exit; use once, right after an
#                               install by an installer that predates manifests
#   --no-verify                 skip the post-apply hook suite (not recommended)
#   -h | --help
#
# Exit codes:
#   0  up to date / check complete / applied cleanly
#   1  APPLIED but verification failed, or the settings merge failed.
#      The update is on disk. Read the report. The rollback command is printed.
#   2  REFUSED before changing anything (bad args, no install, active run,
#      downgrade, missing bundle, missing jq, backup failed)
#
# -----------------------------------------------------------------------------
# STATE FILES OWNED BY THIS SCRIPT  (CONTRACT §0.7: reader and writer together)
# -----------------------------------------------------------------------------
# $TARGET/.claude/.ratchet-version
#     One line, no newline required: the harness semver currently installed,
#     e.g. "1.0.0". Written after a successful --apply and by --adopt-baseline.
#     Read by: this script (version comparison). If absent, the version is
#     recovered from .claude/.ratchet-install.json .installer_version, then from
#     RT_VERSION in .claude/hooks/ratchet.config.sh.
#
# $TARGET/.claude/.ratchet-manifest
#     Checksums of every HARNESS-class file AS THIS SCRIPT WROTE IT. This is the
#     baseline that makes "you edited a harness file" a decidable question
#     instead of a guess.
#       # comment lines begin with '#'
#       <sha256>  <repo-relative-path>
#     Two spaces between fields, so the file is `sha256sum -c` compatible.
#     Written by: --apply, --adopt-baseline.
#     Read by: --check and --apply (local-modification detection).
#     ABSENT is a legal state (installed by an installer that predates this
#     script). It degrades to UNVERIFIED, which is reported, never assumed-clean.
#
# $TARGET/.claude/.backup-<version>-<timestamp>/
#     claude/    a copy of the whole .claude/ tree minus other .backup-* dirs
#     context/   copies of any doctrine doc still living outside .claude/ (legacy)
#     root/      CLAUDE.ratchet.md, if present
#     install.log  the delegated install.sh transcript
#     restore.sh   the one-command rollback. Generated per backup; it names the
#                  exact paths it will restore and touches nothing else.
#
# Files this script APPENDS to (never rewrites):
#   .agent-development/PENDING-HUMAN-ACTIONS.md   one row per follow-up
#   .pipeline/run-events.jsonl                    via .claude/hooks/pipeline-event.sh
# =============================================================================
set -uo pipefail
# NOT set -e. A failed optional step must be REPORTED. Every step that matters
# checks its own exit status. (Same reasoning as install.sh; see the dead-trap
# finding in the source corpus.)

RTU_VERSION="1.0.0"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  printf 'ratchet-update: cannot resolve my own directory\n' >&2; exit 2; }

# ----------------------------------------------------------------- output ---
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
die()   { printf '\n%supdate refused:%s %s\n\n' "$C_R" "$C_0" "$*" >&2; exit 2; }

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# ------------------------------------------------------------------ args ----
MODE="check"
TARGET=""
FROM=""
DRY_RUN=0
ASSUME_YES=0
FORCE_RUN=0
FORCE_OVERWRITE=0
ALLOW_DOWNGRADE=0
ADOPT_BASELINE=0
RUN_VERIFY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --check)                    MODE="check" ;;
    --apply)                    MODE="apply" ;;
    --adopt-baseline)           ADOPT_BASELINE=1 ;;
    --from)                     shift; [ $# -gt 0 ] || die "--from needs a path"; FROM="$1" ;;
    --from=*)                   FROM="${1#--from=}" ;;
    --target)                   shift; [ $# -gt 0 ] || die "--target needs a directory"; TARGET="$1" ;;
    --target=*)                 TARGET="${1#--target=}" ;;
    --dry-run|-n)               DRY_RUN=1 ;;
    --yes|-y)                   ASSUME_YES=1 ;;
    --force)                    FORCE_RUN=1 ;;
    --force-overwrite-modified) FORCE_OVERWRITE=1 ;;
    --allow-downgrade)          ALLOW_DOWNGRADE=1 ;;
    --no-verify)                RUN_VERIFY=0 ;;
    -h|--help)                  usage; exit 0 ;;
    *)                          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ "$DRY_RUN" = "1" ] && [ "$MODE" = "check" ] && MODE="apply"   # --dry-run implies rehearsing an apply

# ============================================================================
# SECTION 1 — helpers
# ============================================================================

# --- sha256, four ways, because Git-Bash is not a promise --------------------
SHA_TOOL=""
rtu_pick_sha() {
  if command -v sha256sum >/dev/null 2>&1; then SHA_TOOL="sha256sum"; return 0; fi
  if command -v shasum    >/dev/null 2>&1; then SHA_TOOL="shasum";    return 0; fi
  if command -v openssl   >/dev/null 2>&1; then SHA_TOOL="openssl";   return 0; fi
  if [ -n "${PY:-}" ]; then SHA_TOOL="python"; return 0; fi
  SHA_TOOL=""
  return 1
}
rtu_sha256() { # rtu_sha256 <file> -> hex on stdout, empty on failure
  [ -f "$1" ] || return 1
  case "$SHA_TOOL" in
    sha256sum) sha256sum -- "$1" 2>/dev/null | awk '{print $1}' ;;
    shasum)    shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}' ;;
    openssl)   openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}' ;;
    python)    "$PY" -c 'import sys,hashlib
h=hashlib.sha256()
with open(sys.argv[1],"rb") as fh:
    for b in iter(lambda: fh.read(65536), b""): h.update(b)
print(h.hexdigest())' "$1" 2>/dev/null ;;
    *)         return 1 ;;
  esac
}

# --- python probe (CONTRACT §4.1) -------------------------------------------
PY=""
rtu_probe_py() {
  local c v
  for c in "${RATCHET_PYTHON:-}" python3 python "py -3"; do
    [ -n "$c" ] || continue
    v="$($c -c 'import sys;print(sys.version_info[0])' 2>/dev/null)"
    if [ "$v" = "3" ]; then PY="$c"; return 0; fi
  done
  return 1
}

# --- semver compare ----------------------------------------------------------
# rtu_semver_cmp A B  -> prints -1 (A<B), 0 (A==B), 1 (A>B)
# Pre-release suffixes are compared as plain strings after the numeric triple,
# and an ABSENT suffix sorts HIGHER than a present one (1.1.0 > 1.1.0-rc1).
rtu_semver_cmp() {
  local a="${1#v}" b="${2#v}" ap bp i x y
  ap="${a#*-}"; [ "$ap" = "$a" ] && ap=""
  bp="${b#*-}"; [ "$bp" = "$b" ] && bp=""
  a="${a%%-*}"; b="${b%%-*}"
  local -a A B
  IFS='.' read -r -a A <<EOF
$a
EOF
  IFS='.' read -r -a B <<EOF
$b
EOF
  for i in 0 1 2; do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    case "$x" in *[!0-9]*|"") x=0 ;; esac
    case "$y" in *[!0-9]*|"") y=0 ;; esac
    if [ "$x" -lt "$y" ]; then printf '%s' -1; return 0; fi
    if [ "$x" -gt "$y" ]; then printf '%s' 1;  return 0; fi
  done
  if [ -z "$ap" ] && [ -n "$bp" ]; then printf '%s' 1;  return 0; fi
  if [ -n "$ap" ] && [ -z "$bp" ]; then printf '%s' -1; return 0; fi
  if [ "$ap" \< "$bp" ]; then printf '%s' -1; return 0; fi
  if [ "$ap" \> "$bp" ]; then printf '%s' 1;  return 0; fi
  printf '%s' 0
}

# --- strip CR (a Windows editor may have touched anything) -------------------
rtu_line() { printf '%s' "${1%$'\r'}"; }

# ============================================================================
# SECTION 2 — THE CLASSIFICATION. Exhaustive by construction.
# ============================================================================
# rtu_classify <repo-relative-path> -> HARNESS | USER | MERGED
#
# Read this function as the specification. Three classes, and the DEFAULT is
# USER — so a path nobody thought about is a path nobody overwrites. That is the
# only default that is safe to be wrong about.
#
#   HARNESS  ours. Replaced wholesale on update. Local edits are detected and
#            preserved as <file>.local-<ts>, never silently discarded.
#   MERGED   settings.json only. Union of permissions, re-wired hooks, your
#            additions preserved, backed up first. Merged by install.sh.
#   USER     yours. NEVER touched. Includes anything unrecognised.
#
# The one sanctioned exception to "USER is never touched" is an APPEND to
# .agent-development/PENDING-HUMAN-ACTIONS.md, which is an append-only register
# that agents are designed to append to. It is called out in the report.
# ---------------------------------------------------------------------------
rtu_classify() {
  local p="$1"
  case "$p" in
    # ---- MERGED -----------------------------------------------------------
    .claude/settings.json)                printf 'MERGED';  return 0 ;;

    # ---- USER: explicit carve-outs INSIDE harness territory ---------------
    # domain.config.sh lives in a harness directory but is not harness-owned:
    # it is the interview's output and it holds this project's walls.
    .claude/hooks/domain.config.sh)       printf 'USER';    return 0 ;;
    .claude/settings.json.bak-*)          printf 'USER';    return 0 ;;
    .claude/.backup-*)                    printf 'USER';    return 0 ;;
    *.local-*)                            printf 'USER';    return 0 ;;

    # ---- HARNESS ----------------------------------------------------------
    .claude/hooks/stack/*.sh)             printf 'HARNESS'; return 0 ;;
    .claude/hooks/*.sh|.claude/hooks/*.py) printf 'HARNESS'; return 0 ;;
    .claude/agents/*.md)                  printf 'HARNESS'; return 0 ;;
    # Doctrine docs. They ship from the harness, they carry no project content
    # of their own, and they are the only channel by which a doctrine change
    # reaches an existing project. They live under .claude/ because that is the
    # harness-owned control layer; .context/ holds only the human's contracts.
    .claude/doctrine/*.md)                printf 'HARNESS'; return 0 ;;
    CLAUDE.ratchet.md)                    printf 'HARNESS'; return 0 ;;

    # ---- USER: the project's own work -------------------------------------
    .context/SPEC.md|.context/MILESTONES.md|.context/DECISIONS.md)
                                          printf 'USER';    return 0 ;;
    .context/archive/*)                   printf 'USER';    return 0 ;;
    .agent-development/*)                 printf 'USER';    return 0 ;;
    .pipeline/*)                          printf 'USER';    return 0 ;;
    secrets/*)                            printf 'USER';    return 0 ;;
    docs/evidence/*)                      printf 'USER';    return 0 ;;
    CLAUDE.md)                            printf 'USER';    return 0 ;;
  esac
  # DEFAULT. Everything else in the repository is the project's.
  printf 'USER'
}

# The HARNESS doctrine docs, listed once so the copier and the reporter agree.
DOCTRINE_DOCS=".claude/doctrine/CLAUDE.md .claude/doctrine/PIPELINE.md .claude/doctrine/TEMPLATE.md .claude/doctrine/UPGRADING.md"

# The never-escalatable control set (CONTRACT §5.6). Drift here is reported at a
# higher volume than drift anywhere else, because nothing lifts these rules and
# a local edit to one of them is a silently disabled wall.
CONTROL_SET="settings.json guard.sh scope-guard.sh hooklib.sh escalation-lib.sh approve.sh ratchet.config.sh"
rtu_in_control_set() { # <repo-relative-path>
  local base; base="$(basename "$1")" ; local c
  for c in $CONTROL_SET; do [ "$c" = "$base" ] && return 0; done
  return 1
}

# ============================================================================
# SECTION 3 — resolve the bundle
# ============================================================================
head1 "Ratchet updater $RTU_VERSION"

rtu_probe_py || true
rtu_pick_sha || die "no usable checksum tool (sha256sum, shasum, openssl or python3).
  Without one, 'has this harness file been edited locally?' is not a decidable
  question, and this updater would be guessing before it overwrote your control
  layer. It will not guess. Install coreutils, or put python3 on PATH."

BUNDLE=""
BUNDLE_TMP=""
cleanup() { [ -n "$BUNDLE_TMP" ] && rm -rf "$BUNDLE_TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

[ -n "$FROM" ] || FROM="$SRC_DIR"
if [ -d "$FROM" ]; then
  BUNDLE="$(cd "$FROM" 2>/dev/null && pwd)"
elif [ -f "$FROM" ]; then
  case "$FROM" in
    *.zip)
      command -v unzip >/dev/null 2>&1 || die "--from is a zip but 'unzip' is not on PATH.
  Extract it yourself and point --from at the directory."
      BUNDLE_TMP="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/rtu.$$")"
      mkdir -p "$BUNDLE_TMP" 2>/dev/null
      unzip -q -o "$FROM" -d "$BUNDLE_TMP" 2>/dev/null || die "could not unzip $FROM"
      # The bundle root is whichever directory holds install.sh AND harness/.
      if [ -d "$BUNDLE_TMP/harness" ] && [ -f "$BUNDLE_TMP/install.sh" ]; then
        BUNDLE="$BUNDLE_TMP"
      else
        BUNDLE="$(find "$BUNDLE_TMP" -maxdepth 3 -type d -name harness 2>/dev/null | head -1)"
        [ -n "$BUNDLE" ] && BUNDLE="$(dirname "$BUNDLE")"
      fi
      [ -n "$BUNDLE" ] || die "that zip does not look like a Ratchet bundle: no directory
  inside it contains both install.sh and harness/."
      ;;
    *) die "--from must be a directory or a .zip (got a file: $FROM)" ;;
  esac
else
  die "--from path does not exist: $FROM"
fi

[ -d "$BUNDLE/harness" ]   || die "$BUNDLE has no harness/ directory. That is not a Ratchet bundle."
[ -f "$BUNDLE/install.sh" ] || die "$BUNDLE has no install.sh.
  This updater deliberately does NOT contain a second copy of the install
  logic — it decides, install.sh writes. Without install.sh there is nothing
  to delegate to."

HARNESS_SRC="$BUNDLE/harness"

BUNDLE_VERSION=""
if [ -f "$BUNDLE/VERSION" ]; then
  BUNDLE_VERSION="$(rtu_line "$(head -1 "$BUNDLE/VERSION" 2>/dev/null)")"
fi
if [ -z "$BUNDLE_VERSION" ] && [ -f "$HARNESS_SRC/.claude/hooks/ratchet.config.sh" ]; then
  BUNDLE_VERSION="$(sed -n 's/^RT_VERSION="\${RT_VERSION:-\([^}]*\)}"/\1/p' \
      "$HARNESS_SRC/.claude/hooks/ratchet.config.sh" 2>/dev/null | head -1)"
fi
[ -n "$BUNDLE_VERSION" ] || die "cannot determine the bundle's version: no VERSION file and no
  RT_VERSION default in harness/.claude/hooks/ratchet.config.sh."

ok "bundle:  $BUNDLE  (version $BUNDLE_VERSION)"

# ============================================================================
# SECTION 4 — resolve the target and read its state
# ============================================================================
[ -n "$TARGET" ] || TARGET="$(pwd)"
[ -d "$TARGET" ] || die "--target does not exist: $TARGET"
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)"
if git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1; then
  TROOT="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$TROOT" ] && [ "$TROOT" != "$TARGET" ]; then
    info "you pointed at a subdirectory; using the repo root: $TROOT"
    TARGET="$TROOT"
  fi
fi

[ -d "$TARGET/.claude/hooks" ] || die "$TARGET does not have a Ratchet install (.claude/hooks/ is absent).
  An update needs something to update. To install for the first time:
      bash \"$BUNDLE/install.sh\" --target \"$TARGET\""

INSTALL_STATE="$TARGET/.claude/.ratchet-install.json"
VERSION_FILE="$TARGET/.claude/.ratchet-version"
MANIFEST="$TARGET/.claude/.ratchet-manifest"

# --- installed version: three sources, most authoritative first -------------
INSTALLED_VERSION=""
VERSION_SOURCE=""
if [ -f "$VERSION_FILE" ]; then
  INSTALLED_VERSION="$(rtu_line "$(head -1 "$VERSION_FILE" 2>/dev/null)")"
  VERSION_SOURCE=".claude/.ratchet-version"
fi
if [ -z "$INSTALLED_VERSION" ] && [ -f "$INSTALL_STATE" ] && command -v jq >/dev/null 2>&1; then
  INSTALLED_VERSION="$(jq -r '.installer_version // empty' "$INSTALL_STATE" 2>/dev/null)"
  [ -n "$INSTALLED_VERSION" ] && VERSION_SOURCE=".claude/.ratchet-install.json"
fi
if [ -z "$INSTALLED_VERSION" ] && [ -f "$TARGET/.claude/hooks/ratchet.config.sh" ]; then
  INSTALLED_VERSION="$(sed -n 's/^RT_VERSION="\${RT_VERSION:-\([^}]*\)}"/\1/p' \
      "$TARGET/.claude/hooks/ratchet.config.sh" 2>/dev/null | head -1)"
  [ -n "$INSTALLED_VERSION" ] && VERSION_SOURCE="RT_VERSION in ratchet.config.sh"
fi
if [ -z "$INSTALLED_VERSION" ]; then
  INSTALLED_VERSION="0.0.0"
  VERSION_SOURCE="UNKNOWN (assumed 0.0.0)"
  warn "cannot determine the installed version. Treating it as 0.0.0, so every"
  say "        harness file will be considered changed."
fi
ok "target:  $TARGET  (version $INSTALLED_VERSION, from $VERSION_SOURCE)"

VCMP="$(rtu_semver_cmp "$INSTALLED_VERSION" "$BUNDLE_VERSION")"
case "$VCMP" in
  -1) VERB="update  $INSTALLED_VERSION -> $BUNDLE_VERSION" ;;
   0) VERB="re-apply $BUNDLE_VERSION (same version)" ;;
   1) VERB="DOWNGRADE $INSTALLED_VERSION -> $BUNDLE_VERSION" ;;
esac

# --- the install answers, so nothing is re-interviewed ----------------------
I_PROJECT=""; I_STACK=""; I_BASE=""; I_ESC=""
if [ -f "$INSTALL_STATE" ] && command -v jq >/dev/null 2>&1; then
  I_PROJECT="$(jq -r '.project_name    // empty' "$INSTALL_STATE" 2>/dev/null)"
  I_STACK="$(  jq -r '.stack           // empty' "$INSTALL_STATE" 2>/dev/null)"
  I_BASE="$(   jq -r '.base_branch     // empty' "$INSTALL_STATE" 2>/dev/null)"
  I_ESC="$(    jq -r '.escalation_mode // empty' "$INSTALL_STATE" 2>/dev/null)"
fi

# ============================================================================
# SECTION 5 — --adopt-baseline (the one-shot fix for a pre-manifest install)
# ============================================================================
# Build the list of HARNESS-class paths present in the TARGET, walking the same
# roots install.sh writes. Used by --adopt-baseline and by the manifest writer.
rtu_target_harness_paths() { # -> repo-relative paths on stdout
  local f rel d
  for d in ".claude/hooks" ".claude/hooks/stack" ".claude/agents"; do
    [ -d "$TARGET/$d" ] || continue
    for f in "$TARGET/$d"/*; do
      [ -f "$f" ] || continue
      rel="$d/$(basename "$f")"
      [ "$(rtu_classify "$rel")" = "HARNESS" ] || continue
      printf '%s\n' "$rel"
    done
  done
  for rel in $DOCTRINE_DOCS CLAUDE.ratchet.md; do
    [ -f "$TARGET/$rel" ] && printf '%s\n' "$rel"
  done
  return 0
}

rtu_write_manifest() { # rtu_write_manifest <version-to-record>
  local v="$1" tmp rel sum
  tmp="$MANIFEST.new"
  {
    printf '# Ratchet harness manifest -- checksums of HARNESS-class files as written.\n'
    printf '# Written by: ratchet-update.sh %s at %s (harness %s)\n' \
      "$RTU_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$v"
    printf '# Read by:    ratchet-update.sh --check/--apply, to decide whether a harness\n'
    printf '#             file was edited LOCALLY before it is overwritten.\n'
    printf '# Format:     "<sha256>  <repo-relative-path>"  (sha256sum -c compatible)\n'
    printf '# Deleting this file does not break anything: every harness file then reports\n'
    printf '# as UNVERIFIED, which is louder, not quieter.\n'
  } > "$tmp" 2>/dev/null || { err "cannot write $MANIFEST"; return 1; }
  rtu_target_harness_paths | sort | while IFS= read -r rel; do
    sum="$(rtu_sha256 "$TARGET/$rel")"
    [ -n "$sum" ] && printf '%s  %s\n' "$sum" "$rel"
  done >> "$tmp" 2>/dev/null
  mv -f "$tmp" "$MANIFEST" 2>/dev/null || { err "cannot install $MANIFEST"; return 1; }
  return 0
}

if [ "$ADOPT_BASELINE" = "1" ]; then
  head1 "Adopting the current tree as the checksum baseline"
  say "  This records what is on disk RIGHT NOW as pristine. Run it only when you"
  say "  know the harness has not been hand-edited since it was installed --"
  say "  typically immediately after an install by an installer that predates"
  say "  .ratchet-manifest. Anything already modified becomes invisible to every"
  say "  future update, which is the one way this file can hurt you."
  if [ "$DRY_RUN" = "1" ]; then
    info "DRY: would write .claude/.ratchet-manifest and .claude/.ratchet-version"
    exit 0
  fi
  if rtu_write_manifest "$INSTALLED_VERSION"; then
    N="$(grep -cv '^#' "$MANIFEST" 2>/dev/null || echo 0)"
    ok "wrote .claude/.ratchet-manifest ($N harness files)"
  else
    die "could not write the manifest"
  fi
  printf '%s\n' "$INSTALLED_VERSION" > "$VERSION_FILE" 2>/dev/null \
    && ok "wrote .claude/.ratchet-version ($INSTALLED_VERSION)" \
    || warn "could not write .claude/.ratchet-version"
  exit 0
fi

# ============================================================================
# SECTION 6 — REFUSALS. All of them fire before anything is written.
# ============================================================================

# --- §RUN: an active run ----------------------------------------------------
RUN_ACTIVE_FILE="$TARGET/.pipeline/run-active"
if [ -f "$RUN_ACTIVE_FILE" ] && [ "$MODE" = "apply" ] && [ "$DRY_RUN" != "1" ]; then
  RUN_MILESTONE="$(rtu_line "$(head -1 "$RUN_ACTIVE_FILE" 2>/dev/null)")"
  if [ "$FORCE_RUN" != "1" ]; then
    printf '\n%supdate refused:%s a run is active (%s).\n\n' "$C_R" "$C_0" "${RUN_MILESTONE:-unnamed}" >&2
    printf '  Swapping the gates mid-run means the run'"'"'s second half is judged by\n' >&2
    printf '  different rules than its first. The scope check, the definition-of-done\n' >&2
    printf '  check and the escalation partition would all change underneath a run that\n' >&2
    printf '  has already made decisions under the old ones, and nothing in the record\n' >&2
    printf '  would say which half of the evidence was collected under which rules.\n\n' >&2
    printf '  Finish or archive the run first:\n' >&2
    printf '      cd "%s" && .claude/hooks/gc-prune.sh archive %s\n\n' "$TARGET" "${RUN_MILESTONE:-<milestone>}" >&2
    if [ ! -f "$TARGET/.pipeline/run-start" ]; then
      printf '  NOTE: there is no .pipeline/run-start beside it, so this may be a leftover\n' >&2
      printf '  rather than a live run -- .claude/hooks/test_hooks.py arms a run as a\n' >&2
      printf '  fixture and does not always clear it. Archive it and re-run; do not reach\n' >&2
      printf '  for --force just because you cannot remember starting a run.\n\n' >&2
    fi
    printf '  --force overrides this. If you use it, say so in DECISIONS.md, because\n' >&2
    printf '  the run'"'"'s retro will otherwise be read as one coherent measurement.\n\n' >&2
    exit 2
  fi
  warn "a run is active ($RUN_MILESTONE) and --force was given."
  say "        The second half of this run will be judged by different rules than its"
  say "        first. File a DECISIONS.md entry saying so, or its retro is not a"
  say "        measurement of anything."
fi

# --- downgrade --------------------------------------------------------------
# In --check this is a warning, not a refusal: --check writes nothing, and
# refusing to even LOOK at a downgrade would hide the one report that tells you
# which gates it removes. The refusal fires when something is about to be
# written.
if [ "$VCMP" = "1" ] && [ "$ALLOW_DOWNGRADE" != "1" ] && [ "$MODE" != "apply" ]; then
  warn "that bundle is OLDER than what is installed ($BUNDLE_VERSION < $INSTALLED_VERSION)."
  say "        Reporting it anyway, because --check writes nothing. --apply would"
  say "        refuse without --allow-downgrade. Read the never-escalatable delta"
  say "        below: on a downgrade it lists the walls this would REMOVE."
fi
if [ "$VCMP" = "1" ] && [ "$ALLOW_DOWNGRADE" != "1" ] && [ "$MODE" = "apply" ]; then
  die "that bundle is OLDER than what is installed ($BUNDLE_VERSION < $INSTALLED_VERSION).
  A downgrade is a legitimate operation — rolling back a bad scaffold is exactly
  what you want sometimes — but it is never what you MEANT when you typed
  'update', and an accidental one silently removes gates you are relying on.
  If you mean it:  --allow-downgrade"
fi

# --- jq: the settings merge is security-relevant, so absent jq BLOCKS -------
# Fatal for --apply only. --check never merges anything, so it degrades to a
# warning there rather than refusing to tell you what an update would do.
if ! command -v jq >/dev/null 2>&1 && [ "$MODE" != "apply" ]; then
  warn "jq is not on PATH. --check still works, but --apply will refuse: the"
  say "        settings.json merge is the permission surface and it is not guessable."
fi
if ! command -v jq >/dev/null 2>&1 && [ "$MODE" = "apply" ]; then
  die "jq is not on PATH.
  settings.json is the permission surface: the deny list is the class of rule
  that cannot be lifted at runtime. Merging it with sed would mean guessing at
  JSON, and a permissive entry that survives a bad guess silently reopens a
  wall. CONTRACT §0.3 — a gate that cannot determine safety BLOCKS.
      Windows: winget install jqlang.jq   macOS: brew install jq
      Debian:  sudo apt-get install jq"
fi

# ============================================================================
# SECTION 7 — CLASSIFY AND DIFF EVERY FILE
# ============================================================================
WORK="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/rtu-work.$$")"
mkdir -p "$WORK" 2>/dev/null || die "cannot create a scratch directory"
trap 'cleanup; rm -rf "$WORK" 2>/dev/null' EXIT

ROWS="$WORK/rows"      # STATUS<TAB>CLASS<TAB>path<TAB>note
: > "$ROWS"

BASELINE_PRESENT=0
[ -f "$MANIFEST" ] && BASELINE_PRESENT=1

rtu_baseline_sum() { # <rel> -> recorded sha, empty if unknown
  [ "$BASELINE_PRESENT" = "1" ] || return 1
  grep -F "  $1" "$MANIFEST" 2>/dev/null | grep -v '^#' | awk '{print $1}' | head -1
}

# The bundle's HARNESS files, as repo-relative install paths.
rtu_bundle_harness_paths() {
  local f rel d
  for d in ".claude/hooks" ".claude/hooks/stack" ".claude/agents"; do
    [ -d "$HARNESS_SRC/$d" ] || continue
    for f in "$HARNESS_SRC/$d"/*; do
      [ -f "$f" ] || continue
      rel="$d/$(basename "$f")"
      [ "$(rtu_classify "$rel")" = "HARNESS" ] || continue
      printf '%s\n' "$rel"
    done
  done
  local doc
  for doc in $DOCTRINE_DOCS; do
    [ -f "$HARNESS_SRC/$doc" ] && printf '%s\n' "$doc"
  done
  # CLAUDE.ratchet.md is only a thing when the project has its own root CLAUDE.md.
  if [ -f "$TARGET/CLAUDE.ratchet.md" ] && [ -f "$HARNESS_SRC/.claude/doctrine/CLAUDE.md" ]; then
    printf '%s\n' "CLAUDE.ratchet.md"
  fi
  return 0
}

# ---- markers make a raw byte compare lie -----------------------------------
# Doctrine docs and agent definitions ship with {{MARKERS}} that install.sh
# substitutes at write time. Comparing the raw bundle file against the
# substituted installed file would report every one of them as changed forever.
# So HARNESS files are compared with markers stripped to a canonical token on
# BOTH sides. Local-modification detection is unaffected: that compares the
# installed file against the recorded checksum of the installed file.
rtu_canon_sum() { # <file> -> sha of the marker-canonicalised bytes
  local f="$1"
  if [ -n "$PY" ]; then
    "$PY" - "$f" <<'PYEOF' 2>/dev/null
import sys, re, hashlib
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
try:
    with open(sys.argv[1], "rb") as fh:
        b = fh.read()
except OSError:
    sys.exit(1)
t = b.replace(b"\r\n", b"\n")
# Any {{MARKER}} and anything that ever replaced one is unknowable from here, so
# only the marker form is canonicalised. That is enough: the bundle side has the
# marker, and the installed side has the value, so we additionally blank the
# lines that CONTAIN a marker on the bundle side. See rtu_harness_differs.
t = re.sub(rb"\{\{[A-Z0-9_]+\}\}", b"<<RTMARK>>", t)
print(hashlib.sha256(t).hexdigest())
PYEOF
  else
    rtu_sha256 "$f"
  fi
}

# rtu_harness_differs <installed-abs> <bundle-abs> -> 0 if MATERIALLY different
# Materially means: different after (a) CRLF normalisation and (b) dropping every
# line of the BUNDLE file that contains a {{MARKER}}, together with the
# corresponding line of the installed file. A marker line cannot be compared
# because its installed form is a substituted value; treating it as a difference
# would make every doctrine doc permanently "changed".
rtu_harness_differs() {
  local inst="$1" bund="$2"
  [ -f "$inst" ] || return 0
  [ -f "$bund" ] || return 1
  if [ -z "$PY" ]; then
    cmp -s "$inst" "$bund" && return 1
    return 0
  fi
  "$PY" - "$inst" "$bund" <<'PYEOF' >/dev/null 2>&1
import sys, re
MARK = re.compile(r"\{\{[A-Z0-9_]+\}\}")
def lines(p):
    with open(p, "rb") as fh:
        return fh.read().replace(b"\r\n", b"\n").split(b"\n")
a, b = lines(sys.argv[1]), lines(sys.argv[2])
if len(a) != len(b):
    sys.exit(1)          # different -> exit 1
for x, y in zip(a, b):
    if MARK.search(y.decode("utf-8", "replace")):
        continue         # marker line: installed side holds a substituted value
    if x != y:
        sys.exit(1)
sys.exit(0)              # same -> exit 0
PYEOF
  [ "$?" = "0" ] && return 1
  return 0
}

N_NEW=0; N_UPDATE=0; N_SAME=0; N_MODIFIED=0; N_UNVERIFIED=0; N_ORPHAN=0
MODIFIED_LIST="$WORK/modified"; : > "$MODIFIED_LIST"
DOCTRINE_TOUCH="$WORK/doctrine"; : > "$DOCTRINE_TOUCH"

rtu_bundle_harness_paths | sort > "$WORK/bundle-paths"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$HARNESS_SRC/$rel"
  case "$rel" in
    .claude/doctrine/*) src="$HARNESS_SRC/$rel" ;;
    CLAUDE.ratchet.md)  src="$HARNESS_SRC/.claude/doctrine/CLAUDE.md" ;;
  esac
  dst="$TARGET/$rel"
  if [ ! -f "$dst" ]; then
    printf 'NEW\tHARNESS\t%s\tnot installed here yet\n' "$rel" >> "$ROWS"
    N_NEW=$((N_NEW+1))
    case "$rel" in .claude/doctrine/*|CLAUDE.ratchet.md) printf '%s\n' "$rel" >> "$DOCTRINE_TOUCH" ;; esac
    continue
  fi
  # Local modification is decided against the RECORDED checksum, never against
  # the bundle. Those are different questions and conflating them is how an
  # upstream change gets reported as your edit.
  base_sum="$(rtu_baseline_sum "$rel")"
  cur_sum="$(rtu_sha256 "$dst")"
  locally_modified=0
  if [ -n "$base_sum" ]; then
    [ "$base_sum" = "$cur_sum" ] || locally_modified=1
  else
    locally_modified=2      # unverifiable
  fi

  if rtu_harness_differs "$dst" "$src"; then
    differs=1
  else
    differs=0
  fi

  if [ "$differs" = "0" ]; then
    if [ "$locally_modified" = "1" ]; then
      # Edited locally, and the edit happens to be exactly what upstream now
      # ships. Nothing to do; say so, because it means their change landed.
      printf 'SAME\tHARNESS\t%s\tlocally edited, but identical to the new version\n' "$rel" >> "$ROWS"
    else
      printf 'SAME\tHARNESS\t%s\t-\n' "$rel" >> "$ROWS"
    fi
    N_SAME=$((N_SAME+1))
    continue
  fi

  case "$locally_modified" in
    1)
      note="LOCAL EDIT -> saved as .local-<ts>"
      [ "$FORCE_OVERWRITE" = "1" ] && note="LOCAL EDIT -> DISCARDED (--force-overwrite-modified)"
      rtu_in_control_set "$rel" && note="CONTROL SET. $note"
      printf 'MODIFIED\tHARNESS\t%s\t%s\n' "$rel" "$note" >> "$ROWS"
      printf '%s\n' "$rel" >> "$MODIFIED_LIST"
      N_MODIFIED=$((N_MODIFIED+1))
      ;;
    2)
      note="differs, and there is no baseline to say whose change it is"
      printf 'UNVERIFIED\tHARNESS\t%s\t%s\n' "$rel" "$note" >> "$ROWS"
      printf '%s\n' "$rel" >> "$MODIFIED_LIST"   # treated as modified: preserved
      N_UNVERIFIED=$((N_UNVERIFIED+1))
      ;;
    *)
      printf 'UPDATE\tHARNESS\t%s\t-\n' "$rel" >> "$ROWS"
      N_UPDATE=$((N_UPDATE+1))
      ;;
  esac
  case "$rel" in .claude/doctrine/*|CLAUDE.ratchet.md) printf '%s\n' "$rel" >> "$DOCTRINE_TOUCH" ;; esac
done < "$WORK/bundle-paths"

# --- ORPHANS: harness files we installed that the new bundle no longer ships -
if [ "$BASELINE_PRESENT" = "1" ]; then
  grep -v '^#' "$MANIFEST" 2>/dev/null | awk '{print $2}' | sort > "$WORK/baseline-paths"
  comm -23 "$WORK/baseline-paths" "$WORK/bundle-paths" 2>/dev/null > "$WORK/orphans"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$TARGET/$rel" ] || continue
    printf 'ORPHAN\tHARNESS\t%s\tthe new bundle no longer ships this; left in place\n' "$rel" >> "$ROWS"
    N_ORPHAN=$((N_ORPHAN+1))
  done < "$WORK/orphans"
fi

# --- settings.json ----------------------------------------------------------
SETTINGS_NOTE="merge: union permissions, re-wire hooks, keep your entries; backed up first"
if [ ! -f "$TARGET/.claude/settings.json" ]; then
  SETTINGS_NOTE="absent; a fresh one will be generated"
fi
printf 'MERGE\tMERGED\t.claude/settings.json\t%s\n' "$SETTINGS_NOTE" >> "$ROWS"

# --- the USER partition, stated as rules, not as 400 unchanged file rows -----
USER_ROWS="$WORK/userrows"; : > "$USER_ROWS"
rtu_user_row() { # <path-or-glob> <what it is>
  local p="$1" what="$2" present="absent"
  case "$p" in
    *"*"*)
      # TARGET stays quoted (Windows paths have spaces); only the glob tail is not.
      for _m in "$TARGET"/$p; do [ -e "$_m" ] && { present="present"; break; }; done ;;
    *)     { [ -e "$TARGET/$p" ] && present="present"; } ;;
  esac
  printf 'KEEP\tUSER\t%s\t%s (%s)\n' "$p" "$what" "$present" >> "$USER_ROWS"
}
rtu_user_row ".claude/hooks/domain.config.sh" "your domain pack: every wall you configured"
rtu_user_row ".context/SPEC.md"               "your requirement ids"
rtu_user_row ".context/MILESTONES.md"         "your WIN rows"
rtu_user_row ".context/DECISIONS.md"          "your decision log"
rtu_user_row ".context/archive/"              "archived decisions"
rtu_user_row ".agent-development/"            "learning loop: retros, lessons, proposals, metrics"
rtu_user_row ".pipeline/"                     "run scratch, findings ledger, checkpoints, events"
rtu_user_row "secrets/"                       "the escalation signing key (never regenerated)"
rtu_user_row "docs/evidence/"                 "WIN-row proof and probe transcripts"
rtu_user_row "CLAUDE.md"                      "your root CLAUDE.md"
rtu_user_row ".claude/settings.json.bak-*"    "every backup any installer took"

# ============================================================================
# SECTION 8 — SEMANTIC DELTAS THAT NEED A HUMAN
# ============================================================================
# Two things can change in a scaffold that a file-level diff reports as "a file
# changed" and a human reads as "so what": a rule that can no longer be lifted,
# and a config default that this project relies on. Both are extracted and named.

NEVER_NEW="$WORK/never-new"; : > "$NEVER_NEW"
rtu_extract_never() { # <escalation-lib.sh path> -> rule ids on stdout
  [ -f "$1" ] || return 0
  sed -n "/^ESC_NEVER_CORE='/,/'$/p;/^ESC_STRICT_NEVER='/,/'$/p" "$1" 2>/dev/null \
    | sed -e "s/^ESC_NEVER_CORE='//" -e "s/^ESC_STRICT_NEVER='//" -e "s/'$//" \
    | tr -d '\r' | sed '/^[[:space:]]*$/d' | sort -u
}
rtu_extract_never "$TARGET/.claude/hooks/escalation-lib.sh"     > "$WORK/never-old"
rtu_extract_never "$HARNESS_SRC/.claude/hooks/escalation-lib.sh" > "$WORK/never-bundle"
comm -13 "$WORK/never-old" "$WORK/never-bundle" 2>/dev/null > "$NEVER_NEW"
NEVER_GONE="$WORK/never-gone"
comm -23 "$WORK/never-old" "$WORK/never-bundle" 2>/dev/null > "$NEVER_GONE"

CFG_CHANGED="$WORK/cfg-changed"; : > "$CFG_CHANGED"
rtu_extract_defaults() { # <ratchet.config.sh> -> "KEY<TAB>default"
  [ -f "$1" ] || return 0
  sed -n 's/^\([A-Z_][A-Z0-9_]*\)="\${\1:-\(.*\)}".*$/\1\t\2/p' "$1" 2>/dev/null | tr -d '\r' | sort -u
}
rtu_extract_defaults "$TARGET/.claude/hooks/ratchet.config.sh"     > "$WORK/cfg-old"
rtu_extract_defaults "$HARNESS_SRC/.claude/hooks/ratchet.config.sh" > "$WORK/cfg-new"
while IFS="$(printf '\t')" read -r k v; do
  [ -n "$k" ] || continue
  old="$(awk -F'\t' -v K="$k" '$1==K{print $2; exit}' "$WORK/cfg-old" 2>/dev/null)"
  [ -n "$old" ] || continue
  [ "$old" = "$v" ] && continue
  # Does this project rely on the old value? Three places say so.
  reliance=""
  grep -q "Default/config.*\b$k\b" "$TARGET/.context/DECISIONS.md" 2>/dev/null \
    && reliance="named in DECISIONS.md"
  grep -qE "^[[:space:]]*(export[[:space:]]+)?$k=" "$TARGET/.claude/hooks/domain.config.sh" 2>/dev/null \
    && reliance="${reliance:+$reliance; }set in domain.config.sh"
  jq -e --arg k "$k" '(.env // {}) | has($k)' "$TARGET/.claude/settings.json" >/dev/null 2>&1 \
    && reliance="${reliance:+$reliance; }set in settings.json .env"
  printf '%s\t%s\t%s\t%s\n' "$k" "$old" "$v" "${reliance:-}" >> "$CFG_CHANGED"
done < "$WORK/cfg-new"

CFG_OVERRIDDEN=0
[ -s "$CFG_CHANGED" ] && CFG_OVERRIDDEN="$(awk -F'\t' '$4!=""' "$CFG_CHANGED" | wc -l | tr -d ' ')"

# --- control-set drift ------------------------------------------------------
CONTROL_DRIFT="$WORK/control-drift"; : > "$CONTROL_DRIFT"
if [ -s "$MODIFIED_LIST" ]; then
  while IFS= read -r rel; do
    rtu_in_control_set "$rel" && printf '%s\n' "$rel" >> "$CONTROL_DRIFT"
  done < "$MODIFIED_LIST"
fi

# --- stale pre-1.2.0 .context/ doctrine copies ------------------------------
# .context/ holds exactly three contracts (CONTRACT.md 1). A pre-1.2.0 build
# also shipped CLAUDE.md/CONVENTIONS.md/PIPELINE.md/TEMPLATE.md/UPGRADING.md
# there; rtu_classify's default (USER) means this updater never touches them,
# so a project installed from that build keeps them forever, diverging
# further from the live doctrine in .claude/doctrine/ every release. Detected
# and reported, never auto-removed --- .context/ is the human's, and this
# updater does not delete USER files.
STALE_CONTEXT_DOCTRINE="$WORK/stale-context-doctrine"; : > "$STALE_CONTEXT_DOCTRINE"
for stale in CLAUDE.md CONVENTIONS.md PIPELINE.md TEMPLATE.md UPGRADING.md; do
  [ -f "$TARGET/.context/$stale" ] && printf '%s\n' "$stale" >> "$STALE_CONTEXT_DOCTRINE"
done
LEGACY_CONTEXT_IMPORT=0
if [ -f "$TARGET/CLAUDE.md" ] && grep -q '@\.context/CLAUDE\.md' "$TARGET/CLAUDE.md" 2>/dev/null; then
  LEGACY_CONTEXT_IMPORT=1
fi

# ============================================================================
# SECTION 9 — THE REPORT
# ============================================================================
head1 "Plan: $VERB"

printf '\n  %-10s %-8s %-42s %s\n' "STATUS" "CLASS" "PATH" "NOTE"
printf '  %s\n' "----------------------------------------------------------------------------------------------"
if [ -s "$ROWS" ]; then
  sort -t"$(printf '\t')" -k2,2 -k1,1 -k3,3 "$ROWS" \
    | awk -F'\t' '{ printf "  %-10s %-8s %-42s %s\n", $1, $2, $3, $4 }'
fi
if [ -s "$USER_ROWS" ]; then
  awk -F'\t' '{ printf "  %-10s %-8s %-42s %s\n", $1, $2, $3, $4 }' "$USER_ROWS"
fi
printf '  %s\n' "----------------------------------------------------------------------------------------------"
printf '  HARNESS  %s new  %s updated  %s unchanged  %s locally-modified  %s unverified  %s orphaned\n' \
  "$N_NEW" "$N_UPDATE" "$N_SAME" "$N_MODIFIED" "$N_UNVERIFIED" "$N_ORPHAN"
printf '  MERGED   1 (.claude/settings.json)\n'
printf '  USER     everything else in this repository, including every path not listed above.\n'
printf '           The classifier'"'"'s default is USER, so an unrecognised path is never touched.\n'

if [ "$BASELINE_PRESENT" != "1" ]; then
  head1 "No checksum baseline"
  warn "there is no .claude/.ratchet-manifest, so 'did someone edit this harness"
  say "        file?' cannot be answered for this install. Every harness file that"
  say "        differs from the bundle is reported UNVERIFIED and will be PRESERVED as"
  say "        a .local-<ts> copy rather than assumed clean."
  say "        This is the expected state exactly once: the install that predates the"
  say "        updater. From this update onward the question is decidable."
fi

if [ -s "$MODIFIED_LIST" ]; then
  head1 "Harness files changed on this machine"
  say "  These are control-layer files that do not match what was installed. The"
  say "  harness's whole claim is that changes to the control layer are DELIBERATE,"
  say "  so they are listed rather than absorbed:"
  say ""
  sed 's/^/      /' "$MODIFIED_LIST"
  say ""
  if [ "$FORCE_OVERWRITE" = "1" ]; then
    warn "--force-overwrite-modified: no .local-* copies will be kept."
    say "        The full backup still holds them; see the rollback command below."
  else
    say "  Each will be copied to <file>.local-<timestamp> beside itself before the"
    say "  new version lands. A .local-* file matches no hook glob (*.sh, *.py) and is"
    say "  wired into nothing, so it is inert: it is a diff waiting for you, not a"
    say "  second control layer."
    say "  Pass --force-overwrite-modified to skip the copies."
  fi
fi

if [ -s "$CONTROL_DRIFT" ]; then
  head1 "CONTROL-SET DRIFT"
  printf '  %sThese are never-escalatable files (CONTRACT 5.6). Nothing lifts a rule in\n' "$C_Y"
  printf '  them: not an approval, not a card, not a domain pack. A local edit to one\n'
  printf '  is a wall that may have been quietly moved:%s\n\n' "$C_0"
  sed 's/^/      /' "$CONTROL_DRIFT"
  say ""
  say "  This is a WARNING, not a refusal, and deliberately so: refusing here would"
  say "  block the very update that restores the control layer to a known state. It"
  say "  is filed in PENDING-HUMAN-ACTIONS.md so it cannot be scrolled past."
fi

if [ -s "$NEVER_NEW" ]; then
  head1 "New never-escalatable rules"
  say "  The new scaffold adds rules that NO approval can lift. Work that used to be"
  say "  possible with a human confirmation may now be a hard wall:"
  say ""
  sed 's/^/      /' "$NEVER_NEW"
fi
if [ -s "$NEVER_GONE" ]; then
  head1 "Rules no longer in the never-escalatable set"
  say "  These were walls and are not any more. Read them as a loosening:"
  say ""
  sed 's/^/      /' "$NEVER_GONE"
fi

if [ -s "$STALE_CONTEXT_DOCTRINE" ] || [ "$LEGACY_CONTEXT_IMPORT" = "1" ]; then
  head1 "STALE .context/ DOCTRINE COPIES"
  if [ -s "$STALE_CONTEXT_DOCTRINE" ]; then
    printf '  %sThese files under .context/ are pre-1.2.0 doctrine, not one of the three\n' "$C_Y"
    printf '  contracts (SPEC/MILESTONES/DECISIONS). They differ from --- and can\n'
    printf '  contradict --- the live doctrine at .claude/doctrine/, and this updater\n'
    printf '  classifies an unrecognised .context/ path as USER, so it has never\n'
    printf '  touched them and will not delete them now:%s\n\n' "$C_0"
    sed 's/^/      .context\//' "$STALE_CONTEXT_DOCTRINE"
    say ""
    say "  Safe to remove by hand once you have confirmed nothing of yours cites"
    say "  them; the doctrine they duplicate lives on at .claude/doctrine/."
  fi
  if [ "$LEGACY_CONTEXT_IMPORT" = "1" ]; then
    say ""
    warn "root CLAUDE.md still imports .context/CLAUDE.md (the pre-1.2.0 chain)."
    say "        Every session in this project loads the STALE copy above instead of"
    say "        .claude/doctrine/CLAUDE.md. Root CLAUDE.md is USER-owned and this"
    say "        updater will not rewrite it for you; change that import line to"
    say "        '@.claude/doctrine/CLAUDE.md' by hand -- the same line a fresh"
    say "        install writes."
  fi
fi

if [ -s "$CFG_CHANGED" ]; then
  head1 "Changed configuration defaults"
  printf '  %-28s %-22s %-22s %s\n' "KEY" "WAS" "NOW" "THIS PROJECT"
  awk -F'\t' '{ printf "  %-28s %-22s %-22s %s\n", $1, $2, $3, ($4==""?"-":$4) }' "$CFG_CHANGED"
  if [ "${CFG_OVERRIDDEN:-0}" -gt 0 ] 2>/dev/null; then
    say ""
    warn "$CFG_OVERRIDDEN of those are values this project has an opinion about."
    say "        A default that moves under a project that overrides it is the quiet"
    say "        kind of breakage: nothing fails, the number is just different now."
  fi
fi

# ============================================================================
# SECTION 10 — --check stops here
# ============================================================================
if [ "$MODE" = "check" ]; then
  head1 "Check complete -- nothing was written"
  if [ "$N_UPDATE" = "0" ] && [ "$N_NEW" = "0" ] && [ "$N_MODIFIED" = "0" ] && [ "$N_UNVERIFIED" = "0" ]; then
    ok "no harness file would change."
  else
    say "  To apply:"
    say "      bash \"$SRC_DIR/$(basename "${BASH_SOURCE[0]}")\" --apply --target \"$TARGET\" --from \"$FROM\""
    say ""
    say "  To rehearse it first (writes nothing, runs install.sh --dry-run):"
    say "      ... --apply --dry-run"
  fi
  exit 0
fi

# ============================================================================
# SECTION 11 — CONFIRM
# ============================================================================
if [ "$DRY_RUN" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
  DIRTY="$(git -C "$TARGET" status --porcelain 2>/dev/null | grep -v '^??' | head -10)"
  if [ -n "$DIRTY" ]; then
    head1 "Modified tracked files in the target"
    printf '%s\n' "$DIRTY" | sed 's/^/      /'
    say ""
    say "  Not a refusal: this updater takes its own full backup of .claude/ and"
    say "  gives you a one-command rollback, which is stronger than 'git checkout .'."
    say "  It is shown so you know what else is in flight."
  fi
  if [ ! -t 0 ]; then
    die "no terminal to confirm on, and --yes was not given.
  An unattended process just tried to replace this project's control layer. If
  that was you, say so explicitly:  --yes"
  fi
  printf '\n  %sProceed with: %s%s  [y/N] ' "$C_B" "$VERB" "$C_0"
  read -r REPLY_ANS
  case "$REPLY_ANS" in
    y|Y|yes|YES) ;;
    *) say ""; say "  Aborted. Nothing was written."; exit 0 ;;
  esac
fi

# ============================================================================
# SECTION 12 — BACKUP. Before one byte is written.
# ============================================================================
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BK_REL=".claude/.backup-$INSTALLED_VERSION-$TS"
BK="$TARGET/$BK_REL"
ROLLBACK="bash $BK_REL/restore.sh"

if [ "$DRY_RUN" = "1" ]; then
  head1 "Backup (dry run)"
  info "DRY: would copy .claude/ (minus other .backup-*) to $BK_REL/claude/"
  info "DRY: the doctrine docs it rewrites ride along in that .claude/ copy"
  info "DRY: would generate $BK_REL/restore.sh"
else
  head1 "Backup"
  mkdir -p "$BK/claude" 2>/dev/null || die "cannot create the backup directory $BK_REL.
  Nothing has been written. An update without a backup is not an update, it is a
  hope, so this is a refusal and not a warning."
  BK_OK=1
  for e in "$TARGET/.claude"/* "$TARGET/.claude"/.[!.]*; do
    [ -e "$e" ] || continue
    b="$(basename "$e")"
    case "$b" in .backup-*) continue ;; esac
    cp -R "$e" "$BK/claude/" 2>/dev/null || { err "could not back up .claude/$b"; BK_OK=0; }
  done
  [ "$BK_OK" = "1" ] || die "the backup is incomplete. Nothing else was written."
  BK_N="$(find "$BK/claude" -type f 2>/dev/null | wc -l | tr -d ' ')"
  ok "backed up .claude/ -> $BK_REL/claude/ ($BK_N files)"

  if [ -s "$DOCTRINE_TOUCH" ]; then
    while IFS= read -r rel; do
      [ -f "$TARGET/$rel" ] || continue
      case "$rel" in
        CLAUDE.ratchet.md) mkdir -p "$BK/root" 2>/dev/null; cp -f "$TARGET/$rel" "$BK/root/" 2>/dev/null ;;
        .claude/*)         : ;;   # already inside the whole-.claude/ copy taken above
        *)                 mkdir -p "$BK/context" 2>/dev/null; cp -f "$TARGET/$rel" "$BK/context/" 2>/dev/null ;;
      esac
    done < "$DOCTRINE_TOUCH"
    ok "backed up the doctrine docs this update rewrites"
  fi

  # --- the rollback script ---------------------------------------------------
  # Generated per backup and explicit about every path it touches. It restores
  # the control layer and NOTHING else: your .pipeline/, .agent-development/,
  # SPEC, MILESTONES, DECISIONS and secrets were never modified, so putting them
  # back would be a change, not a rollback.
  cat > "$BK/restore.sh" <<RESTOREEOF
#!/usr/bin/env bash
# Ratchet rollback -- generated by ratchet-update.sh $RTU_VERSION at $TS.
# Restores the control layer to harness $INSTALLED_VERSION, exactly as it was
# immediately before the update to $BUNDLE_VERSION.
#
# It restores:   .claude/hooks/  .claude/agents/  .claude/settings.json
#                the .claude/ dotfiles, and the doctrine docs under .claude/doctrine/
# It does NOT touch: .pipeline/  .agent-development/  secrets/  docs/evidence/
#                .context/SPEC.md  MILESTONES.md  DECISIONS.md  your CLAUDE.md
# Nothing in that second list was modified by the update, so restoring it would
# be a change rather than a rollback. The one row appended to
# PENDING-HUMAN-ACTIONS.md is left in place on purpose: it is the record that
# this happened.
set -uo pipefail
BK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 2
R="\$(cd "\$BK/../.." 2>/dev/null && pwd)" || exit 2
[ -d "\$BK/claude" ] || { printf 'rollback: backup payload missing at %s\n' "\$BK/claude" >&2; exit 2; }
printf 'Rolling %s back to Ratchet $INSTALLED_VERSION ...\n' "\$R"
rm -rf "\$R/.claude/hooks" "\$R/.claude/agents" "\$R/.claude/doctrine"
rm -f  "\$R/.claude/settings.json" "\$R/.claude/.ratchet-version" \\
       "\$R/.claude/.ratchet-manifest" "\$R/.claude/.ratchet-install-manifest" \\
       "\$R/.claude/.ratchet-install.json"
cp -R "\$BK/claude/." "\$R/.claude/" || { printf 'rollback FAILED copying .claude\n' >&2; exit 2; }
if [ -d "\$BK/context" ]; then cp -R "\$BK/context/." "\$R/.context/" 2>/dev/null; fi
if [ -d "\$BK/root" ];    then cp -R "\$BK/root/."    "\$R/"          2>/dev/null; fi
for f in "\$R/.claude/hooks"/*.sh "\$R/.claude/hooks"/*.py "\$R/.claude/hooks/stack"/*.sh; do
  [ -f "\$f" ] && chmod +x "\$f" 2>/dev/null
done
printf 'Rolled back. Now re-run the suite, because a rollback is a change too:\n'
printf '    cd "%s" && python3 .claude/hooks/test_hooks.py\n' "\$R"
printf 'The .local-* copies this update left behind (if any) are still on disk.\n'
exit 0
RESTOREEOF
  chmod +x "$BK/restore.sh" 2>/dev/null
  ok "rollback script: $BK_REL/restore.sh"
  printf '\n  %sROLLBACK, any time:%s  cd %s && %s\n\n' "$C_B" "$C_0" "$TARGET" "$ROLLBACK"
fi

# ============================================================================
# SECTION 13 — APPLY
# ============================================================================
head1 "Applying"

# --- 13.1 doctrine docs. install.sh replaces .claude/doctrine/ wholesale, the
# same way it replaces the hooks; the updater still places them here first so
# CLAUDE.ratchet.md is covered too, and lets install.sh's substitution pass fill
# the {{MARKERS}} afterwards.
if [ -s "$DOCTRINE_TOUCH" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      CLAUDE.ratchet.md) src="$HARNESS_SRC/.claude/doctrine/CLAUDE.md" ;;
      *)                 src="$HARNESS_SRC/$rel" ;;
    esac
    [ -f "$src" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
      info "DRY: write $rel (doctrine doc)"
      continue
    fi
    mkdir -p "$(dirname "$TARGET/$rel")" 2>/dev/null
    if LC_ALL=C tr -d '\r' < "$src" > "$TARGET/$rel.rtu-tmp" 2>/dev/null; then
      mv -f "$TARGET/$rel.rtu-tmp" "$TARGET/$rel" 2>/dev/null \
        || { cp -f "$TARGET/$rel.rtu-tmp" "$TARGET/$rel"; rm -f "$TARGET/$rel.rtu-tmp"; }
      ok "doctrine doc: $rel"
    else
      rm -f "$TARGET/$rel.rtu-tmp" 2>/dev/null
      cp -f "$src" "$TARGET/$rel" 2>/dev/null && ok "doctrine doc: $rel" || err "could not write $rel"
    fi
  done < "$DOCTRINE_TOUCH"
fi

# --- 13.2 delegate to install.sh -------------------------------------------
# This is the whole point. install.sh already knows how to replace the harness,
# keep user files, merge settings.json, substitute markers, chmod the hooks and
# not regenerate the escalation key. A second implementation of any of that is a
# second thing to get wrong. --force is passed because THIS script has already
# taken a backup that is stronger than the dirty-worktree check install.sh would
# otherwise apply; --no-verify because the suite is run below, where the report
# can put the rollback command next to a failure.
set -- --target "$TARGET" --domain none --no-verify --force
[ -n "$I_STACK" ]   && set -- "$@" --stack "$I_STACK"
[ -n "$I_PROJECT" ] && set -- "$@" --project-name "$I_PROJECT"
[ -n "$I_BASE" ]    && set -- "$@" --base-branch "$I_BASE"
[ -n "$I_ESC" ]     && set -- "$@" --escalation-mode "$I_ESC"
[ "$DRY_RUN" = "1" ] && set -- "$@" --dry-run

if [ -z "$I_STACK" ]; then
  warn "no .claude/.ratchet-install.json, so the stack pack and project name are"
  say "        being re-detected rather than remembered. Check the report below; if the"
  say "        stack is wrong, re-run install.sh once with the right --stack."
fi

if [ "$DRY_RUN" = "1" ]; then
  INSTALL_LOG="$WORK/install.log"
else
  INSTALL_LOG="$BK/install.log"
fi

info "delegating the file writes to install.sh $BUNDLE_VERSION ..."
NO_COLOR=1 bash "$BUNDLE/install.sh" "$@" > "$INSTALL_LOG" 2>&1
INSTALL_RC=$?
if [ "$INSTALL_RC" = "0" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    ok "install.sh --dry-run completed (it wrote nothing either)"
  else
    ok "install.sh completed (transcript: $BK_REL/install.log)"
  fi
else
  err "install.sh exited $INSTALL_RC. Last 25 lines:"
  tail -25 "$INSTALL_LOG" 2>/dev/null | sed 's/^/      /'
fi
# Surface the two lines that matter regardless of exit code.
grep -E "merged: allow|wrote .claude/settings.json|NOT modified" "$INSTALL_LOG" 2>/dev/null \
  | sed 's/^ *//' | sed 's/^/      /'
SETTINGS_FAILED=0
grep -q "the merge produced invalid JSON" "$INSTALL_LOG" 2>/dev/null && SETTINGS_FAILED=1

# --- what the merge took away from YOU --------------------------------------
# The merge is a union with one deliberate asymmetry: our deny beats your allow
# and your ask, because deny is the class that cannot be lifted at runtime and a
# permissive entry that survived a merge would silently reopen a wall. That is
# correct, and it is also the one thing in the merge a human would want told to
# them by name rather than discovered later by being blocked.
if [ "$DRY_RUN" != "1" ] && [ -f "$BK/claude/settings.json" ] && [ -f "$TARGET/.claude/settings.json" ]; then
  DROPPED="$(jq -r --slurpfile new "$TARGET/.claude/settings.json" '
      (($new[0].permissions.allow // []) + ($new[0].permissions.ask // [])) as $keep
      | ((.permissions.allow // []) + (.permissions.ask // []))
      | map(select(. as $e | ($keep | index($e)) == null))
      | unique | .[]' "$BK/claude/settings.json" 2>/dev/null)"
  if [ -n "$DROPPED" ]; then
    warn "permission entries you had are gone, because harness $BUNDLE_VERSION denies them:"
    printf '%s\n' "$DROPPED" | sed 's/^/          /'
    say "        Our deny beats your allow and your ask. If one of these is load-bearing"
    say "        for this project, it does not go back in settings.json by hand: it is a"
    say "        domain-pack question (SECRET_EXEMPTIONS, FORBIDDEN_EXEC_TOKENS) or a"
    say "        named local patch. See .claude/doctrine/UPGRADING.md section 5."
  fi
fi

# --- CLAUDE.ratchet.md, which install.sh writes on every re-run -------------
# install.sh's first run writes a root CLAUDE.md containing the one-line import
# `@.claude/doctrine/CLAUDE.md`. Every run after that sees a root CLAUDE.md, concludes
# the project had its own, and writes CLAUDE.ratchet.md plus a warning saying
# the doctrine is "installed but not loaded" -- which is false when the import
# is already there. Say so, once, rather than let the warning stand.
if [ "$DRY_RUN" != "1" ] && [ -f "$TARGET/CLAUDE.ratchet.md" ] \
   && grep -q '@\.claude/doctrine/CLAUDE\.md' "$TARGET/CLAUDE.md" 2>/dev/null; then
  info "CLAUDE.ratchet.md was (re)written by install.sh, but your root CLAUDE.md"
  info "  already imports @.claude/doctrine/CLAUDE.md, so the doctrine IS loaded and that"
  info "  file is a redundant copy. Deleting it is safe and this updater will not"
  info "  put it back unless install.sh does."
fi

# --- 13.3 preserve the local edits -----------------------------------------
LOCAL_SAVED="$WORK/local-saved"; : > "$LOCAL_SAVED"
if [ -s "$MODIFIED_LIST" ] && [ "$FORCE_OVERWRITE" != "1" ]; then
  head1 "Preserving your harness edits"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
      info "DRY: save $rel -> $rel.local-$TS"
      continue
    fi
    # The byte-exact pre-update copy is in the backup, which is why the .local
    # file is written from THERE and not from the live tree: by now the live
    # tree has been rewritten and marker-substituted.
    case "$rel" in
      CLAUDE.ratchet.md) srcbk="$BK/root/CLAUDE.ratchet.md" ;;
      .claude/*)         srcbk="$BK/claude/${rel#.claude/}" ;;
      .context/*)        srcbk="$BK/context/$(basename "$rel")" ;;
      *)                 srcbk="" ;;
    esac
    if [ -n "$srcbk" ] && [ -f "$srcbk" ]; then
      cp -f "$srcbk" "$TARGET/$rel.local-$TS" 2>/dev/null \
        && { ok "$rel.local-$TS"; printf '%s\n' "$rel.local-$TS" >> "$LOCAL_SAVED"; } \
        || err "could not preserve $rel"
    else
      err "no backup copy of $rel to preserve (looked in $srcbk)"
    fi
  done < "$MODIFIED_LIST"
  if [ -s "$LOCAL_SAVED" ]; then
    say ""
    say "  Diff each one against what just landed, decide, then delete it:"
    FIRST_LOCAL="$(head -1 "$LOCAL_SAVED")"
    say "      diff \"${FIRST_LOCAL%.local-$TS}\" \"$FIRST_LOCAL\""
    say "  If the edit is still wanted, it does not go back in by hand: it goes"
    say "  upstream, or it becomes a named local patch. See .claude/doctrine/UPGRADING.md."
  fi
fi

# --- 13.4 version + manifest ------------------------------------------------
if [ "$DRY_RUN" != "1" ]; then
  printf '%s\n' "$BUNDLE_VERSION" > "$VERSION_FILE" 2>/dev/null \
    && ok "recorded .claude/.ratchet-version = $BUNDLE_VERSION" \
    || warn "could not write .claude/.ratchet-version"
  if rtu_write_manifest "$BUNDLE_VERSION"; then
    MN="$(grep -cv '^#' "$MANIFEST" 2>/dev/null || echo 0)"
    ok "recorded .claude/.ratchet-manifest ($MN harness checksums)"
    say "      From here, 'did someone edit a harness file?' is a decidable question."
  else
    warn "could not write .claude/.ratchet-manifest; the next update will report"
    say "        every differing harness file as UNVERIFIED."
  fi
else
  info "DRY: would record .ratchet-version and .ratchet-manifest"
fi

# ============================================================================
# SECTION 14 — HUMAN FOLLOW-UP: PENDING-HUMAN-ACTIONS + a pipeline event
# ============================================================================
PHA="$TARGET/.agent-development/PENDING-HUMAN-ACTIONS.md"

# Names are permanent and never reused (CONTRACT §6), so a repeated condition
# gets a step counter rather than the same name twice.
rtu_pha_name() { # <base-name> -> base-name-<n>
  local base="$1" n=1
  if [ -f "$PHA" ]; then
    while grep -q "| $base-$n |" "$PHA" 2>/dev/null; do n=$((n+1)); done
  fi
  printf '%s-%s' "$base" "$n"
}
PHA_ROWS="$WORK/pha"; : > "$PHA_ROWS"
D="$(date -u +%Y-%m-%d)"
rtu_file_action() { # <base-name> <action text>
  local nm; nm="$(rtu_pha_name "$1")"
  printf '| %s | %s | human | %s | OPEN |\n' "$nm" "$D" "$2" >> "$PHA_ROWS"
  printf '%s\n' "$nm"
}

if [ -s "$NEVER_NEW" ]; then
  NL="$(tr '\n' ' ' < "$NEVER_NEW" | sed 's/ *$//')"
  rtu_file_action "new-never-escalatable-rules" \
"Harness $INSTALLED_VERSION -> $BUNDLE_VERSION added never-escalatable rule ids: \`$NL\`. Nothing lifts these -- not \`approve.sh\`, not a Decision Card, not the domain pack. Re-read \`.claude/hooks/escalation-lib.sh\` and confirm no standing workflow in this project depends on one of them being confirmable. If one does, that workflow now needs redesigning, not approving." >/dev/null
fi
if [ "${CFG_OVERRIDDEN:-0}" -gt 0 ] 2>/dev/null; then
  KL="$(awk -F'\t' '$4!=""{printf "%s ", $1}' "$CFG_CHANGED" | sed 's/ *$//')"
  rtu_file_action "config-default-changed-under-override" \
"Harness $INSTALLED_VERSION -> $BUNDLE_VERSION changed the default of: \`$KL\` -- and this project has a recorded opinion about each of them. Nothing failed; the number is just different now. Confirm the project's value is still the one you want and, if it is, that it is set somewhere the update cannot move (DECISIONS.md plus an explicit export), not inherited from a default." >/dev/null
fi
if [ -s "$CONTROL_DRIFT" ]; then
  CL="$(tr '\n' ' ' < "$CONTROL_DRIFT" | sed 's/ *$//')"
  rtu_file_action "control-set-drift-detected" \
"Before this update, these never-escalatable control-set files did not match what was installed: \`$CL\`. They have been replaced with harness $BUNDLE_VERSION and the previous contents kept as \`.local-$TS\`. Read the diff and decide whether the edit was a deliberate local patch (record it in DECISIONS.md and see \`.claude/doctrine/UPGRADING.md\`), or drift that should stay gone." >/dev/null
elif [ -s "$MODIFIED_LIST" ]; then
  ML="$(tr '\n' ' ' < "$MODIFIED_LIST" | sed 's/ *$//')"
  rtu_file_action "harness-files-locally-modified" \
"These harness files did not match what was installed and were replaced by harness $BUNDLE_VERSION, with the previous contents kept as \`.local-$TS\`: \`$ML\`. Diff each, then either propose the change upstream or record it as a named local patch in DECISIONS.md. Deleting the \`.local-*\` file is how you close this row." >/dev/null
fi

if [ -s "$PHA_ROWS" ] && [ "$DRY_RUN" != "1" ]; then
  head1 "Filed for a human"
  if [ ! -f "$PHA" ]; then
    mkdir -p "$TARGET/.agent-development" 2>/dev/null
    {
      printf '# PENDING HUMAN ACTIONS\n\n'
      printf 'Agents APPEND here. Humans close rows by editing the Status column to DONE.\n\n'
      printf '| name | opened | who | action | status |\n|---|---|---|---|---|\n'
    } > "$PHA" 2>/dev/null
  fi
  cat "$PHA_ROWS" >> "$PHA" 2>/dev/null \
    && awk -F'|' '{print $2}' "$PHA_ROWS" | sed 's/^ *//;s/ *$//' | sed 's/^/      /' \
    || warn "could not append to $PHA"
  say ""
  say "  Appending to PENDING-HUMAN-ACTIONS.md is the one sanctioned write into the"
  say "  USER partition: it is an append-only register that exists to be appended to."
elif [ -s "$PHA_ROWS" ]; then
  head1 "Would file for a human"
  awk -F'|' '{print $2}' "$PHA_ROWS" | sed 's/^ *//;s/ *$//' | sed 's/^/      DRY: /'
fi

# --- the event --------------------------------------------------------------
if [ "$DRY_RUN" != "1" ] && [ -x "$TARGET/.claude/hooks/pipeline-event.sh" ]; then
  ( cd "$TARGET" && ./.claude/hooks/pipeline-event.sh harness_updated \
      "from=$INSTALLED_VERSION" "to=$BUNDLE_VERSION" \
      "updated=$N_UPDATE" "new=$N_NEW" "modified_preserved=$N_MODIFIED" \
      "unverified=$N_UNVERIFIED" "orphaned=$N_ORPHAN" \
      "backup=$BK_REL" "forced_over_active_run=$FORCE_RUN" ) >/dev/null 2>&1 \
    && ok "emitted harness_updated to .pipeline/run-events.jsonl" \
    || warn "could not emit the pipeline event (the update itself is unaffected)"
fi

# ============================================================================
# SECTION 15 — VERIFY. And do NOT auto-roll-back on failure.
# ============================================================================
VERIFY_STATE="not run"
VERIFY_RC=0
if [ "$DRY_RUN" = "1" ]; then
  VERIFY_STATE="skipped (dry run)"
elif [ "$RUN_VERIFY" != "1" ]; then
  VERIFY_STATE="SKIPPED (--no-verify)"
  warn "the hook suite was not run. An unverified control layer is the one thing"
  say "        this harness cannot check for you."
elif [ -f "$TARGET/.claude/hooks/test_hooks.py" ] && [ -n "$PY" ]; then
  head1 "Verification (test_hooks.py)"
  RUN_ACTIVE_BEFORE_SUITE=0
  [ -f "$RUN_ACTIVE_FILE" ] && RUN_ACTIVE_BEFORE_SUITE=1
  VT="${RATCHET_UPDATE_VERIFY_TIMEOUT:-900}"
  info "running the hook suite (bounded at ${VT}s)..."
  if command -v timeout >/dev/null 2>&1; then
    VOUT="$(cd "$TARGET" && timeout "$VT" $PY .claude/hooks/test_hooks.py 2>&1)"; VERIFY_RC=$?
  else
    VOUT="$(cd "$TARGET" && $PY .claude/hooks/test_hooks.py 2>&1)"; VERIFY_RC=$?
  fi
  if [ "$VERIFY_RC" = "124" ]; then
    VERIFY_STATE="TIMED OUT after ${VT}s"
    warn "the suite did not finish in ${VT}s. That is not a pass and not a failure --"
    say "        it is a check that did not run. Treat it as unknown and re-run it."
  elif [ "$VERIFY_RC" = "0" ]; then
    VERIFY_STATE="PASS"
    ok "hook suite green on harness $BUNDLE_VERSION"
  else
    VERIFY_STATE="FAIL"
    err "hook suite FAILED after the update (exit $VERIFY_RC)"
    printf '%s\n' "$VOUT" | tail -30 | sed 's/^/      /'
  fi
else
  VERIFY_STATE="SKIPPED (no test_hooks.py or no python3)"
  warn "$VERIFY_STATE"
fi

# --- re-baseline the postcondition -----------------------------------------
# The control-layer postcondition is judged against a recorded floor of what
# this host already fails. The update changed the suite, so the old floor is
# describing a different program. Re-record it -- but ONLY from a green run: a
# floor taken from a red suite bakes today's breakage in as normal and the
# postcondition then passes while the control layer is genuinely broken.
if [ "$DRY_RUN" != "1" ] && [ "$VERIFY_STATE" = "PASS" ] && [ -x "$TARGET/.claude/hooks/approve.sh" ]; then
  PCB_TO=""
  command -v timeout >/dev/null 2>&1 && PCB_TO="timeout ${RATCHET_UPDATE_VERIFY_TIMEOUT:-900}"
  info "re-recording the control-layer postcondition baseline..."
  if ( cd "$TARGET" && $PCB_TO ./.claude/hooks/approve.sh --postcondition-baseline ) >/dev/null 2>&1; then
    ok "postcondition baseline re-recorded against harness $BUNDLE_VERSION"
  else
    warn "could not re-record the postcondition baseline. Run it yourself:"
    say "            cd \"$TARGET\" && .claude/hooks/approve.sh --postcondition-baseline"
    say "        A baseline from the OLD suite describes a different program."
  fi
elif [ "$DRY_RUN" != "1" ] && [ "$VERIFY_STATE" != "PASS" ]; then
  warn "NOT re-recording the postcondition baseline: the suite is not green."
  say "        A floor taken from a red suite records today's breakage as normal."
fi

# The suite (and the postcondition baseline, which re-runs it) arms a run as a
# fixture and does not always clear it. This script must not clear it either:
# gc-prune.sh owns every run-lifecycle transition (CONTRACT §5.1) and a second
# writer to RUN_ACTIVE is exactly the kind of split ownership that makes a state
# file untrustworthy. So: say so, and check AFTER the last thing that runs the
# suite, not after the first.
if [ "$DRY_RUN" != "1" ] && [ "${RUN_ACTIVE_BEFORE_SUITE:-1}" = "0" ] && [ -f "$RUN_ACTIVE_FILE" ]; then
  RA="$(rtu_line "$(head -1 "$RUN_ACTIVE_FILE" 2>/dev/null)")"
  warn "the hook suite left a run armed (.pipeline/run-active = ${RA:-?})."
  say "        Nothing is wrong with your repo, but until it is cleared the scope"
  say "        checks and the Stop gate's definition-of-done checks are LIVE, and the"
  say "        next update will refuse. gc-prune.sh owns that file, so clear it there:"
  say "            cd \"$TARGET\" && .claude/hooks/gc-prune.sh archive ${RA:-<milestone>}"
fi

# ============================================================================
# SECTION 16 — REPORT
# ============================================================================
head1 "======================================================================"
if [ "$DRY_RUN" = "1" ]; then
  say "  DRY RUN COMPLETE. Nothing above was written."
  say "  Re-run without --dry-run to apply."
  head1 "======================================================================"
  exit 0
fi

say "  Ratchet $INSTALLED_VERSION -> $BUNDLE_VERSION in: $TARGET"
say "    harness files   $N_UPDATE updated, $N_NEW new, $N_SAME unchanged, $N_ORPHAN orphaned"
say "    preserved       $N_MODIFIED locally-modified, $N_UNVERIFIED unverified"
say "    settings.json   $([ "$SETTINGS_FAILED" = "1" ] && echo 'MERGE FAILED -- not modified' || echo 'merged (yours kept, our deny wins ties)')"
say "    verification    $VERIFY_STATE"
say "    warnings        $WARNINGS"
say "    untouched       .context/SPEC.md .context/MILESTONES.md .context/DECISIONS.md"
say "                    .claude/hooks/domain.config.sh  .agent-development/  .pipeline/"
say "                    secrets/  docs/evidence/  and every path not listed above"

if [ -s "$LOCAL_SAVED" ]; then
  say ""
  say "  Your harness edits are on disk, beside the files they came from:"
  sed 's/^/      /' "$LOCAL_SAVED"
fi

say ""
printf '  %sROLLBACK (one command, works any time):%s\n' "$C_B" "$C_0"
say "      cd $TARGET && $ROLLBACK"

if [ "$VERIFY_STATE" = "FAIL" ]; then
  printf '\n  %s====================================================================%s\n' "$C_R" "$C_0"
  printf '  %sTHE HOOK SUITE IS RED ON THE NEW HARNESS.%s\n\n' "$C_R" "$C_0"
  printf '  This update was NOT rolled back automatically, and that is deliberate: an\n'
  printf '  automatic rollback would leave you with a working harness and no record\n'
  printf '  that the new one is broken, which is how a broken release ships twice.\n\n'
  printf '  Roll back now:\n'
  printf '      cd %s && %s\n\n' "$TARGET" "$ROLLBACK"
  printf '  Or investigate first -- the old tree is intact in %s:\n' "$BK_REL"
  printf '      cd %s && %s .claude/hooks/test_hooks.py\n' "$TARGET" "${PY:-python3}"
  printf '  %s====================================================================%s\n\n' "$C_R" "$C_0"
fi

head1 "FIRST SESSION AFTER AN UPDATE"
say ""
say "  Read .claude/doctrine/UPGRADING.md -- it is the doctrine for this, and the update"
say "  may have just rewritten it. The short version:"
say "    1. Re-read .agent-development/ACTIVE-LESSONS.md; a lesson can be obsoleted"
say "       by a scaffold change and a stale lesson costs tokens every run."
say "    2. Run the project's own suite, not just the hook suite."
say "    3. Read the new never-escalatable rules above. Something that used to be"
say "       approvable may now be a wall."
say "    4. Close the rows this update filed in PENDING-HUMAN-ACTIONS.md."
head1 "======================================================================"

if [ "$VERIFY_STATE" = "FAIL" ] || [ "$SETTINGS_FAILED" = "1" ]; then
  exit 1
fi
exit 0
