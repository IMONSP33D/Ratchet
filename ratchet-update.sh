#!/usr/bin/env bash
# =============================================================================
# ratchet-update.sh — mid-project updater for the RATCHET harness.
#
# THE PROBLEM THIS SOLVES
#   Ratchet is a vendoring product, not a repo you clone: it copies an agent
#   stack into someone else's project, and "update" has to bring a newer
#   Ratchet into a tree that has since diverged, without clobbering their
#   edits. That is template vendoring with a three-way merge — the thing
#   https://copier.readthedocs.io does, and cookiecutter never solved.
#
# THE DESIGN (RATCHET-DECISIONS-2026-08-23 §1.2)
#   1. install.sh is the only writer of the baseline: at the end of every
#      install it records .claude/.ratchet-version and .claude/.ratchet-manifest
#      (two sha256 columns per HARNESS file — installed-hash and a
#      marker-canonicalised template-hash; see install.sh SECTION 13).
#   2. This script CLASSIFIES; it never writes a harness file itself. Every
#      path gets a real 3-way compare — old-template vs new-template vs
#      on-disk — and one of five verdicts:
#        SAME      old==disk, old==new   -> nothing to do
#        UPDATE    old==disk, old!=new   -> clean upgrade, overwrite
#        KEEP      old!=disk, old==new   -> user-owned now, leave it
#        CONFLICT  old!=disk, old!=new   -> the only interesting case:
#                                            write <path>.ratchet-merge, report
#        NEW / UNVERIFIED                -> no baseline; install / flag
#   3. install.sh does the actual writing (harness copy, {{MARKER}} substitution,
#      the one settings.json merge in this codebase). This script runs it, then
#      un-does its overwrite of every KEEP and CONFLICT path.
#   4. Report the conflicts as a list and stop. No rollback script, no backup
#      directory, no generated shell — a CONFLICT file is never touched, so
#      there is nothing to roll back to.
#
# Usage:
#   ./ratchet-update.sh --check --target ../my-repo --from /path/to/ratchet-1.1.0
#   ./ratchet-update.sh --apply --target ../my-repo --yes
#   ./ratchet-update.sh --apply --target ../my-repo --dry-run
#   ./ratchet-update.sh --adopt-baseline --target ../my-repo   # pre-manifest installs
#
# Options:
#   --check              (DEFAULT) report what WOULD change; write nothing
#   --apply              perform the update
#   --from <path>        bundle directory or .zip        (default: my own dir)
#   --target <repo>      repo to update                  (default: cwd)
#   --dry-run            rehearse --apply (passes --dry-run to install.sh)
#   --yes                do not prompt for confirmation
#   --allow-downgrade    permit installing an OLDER version
#   --adopt-baseline     re-run install.sh --target once to record a baseline for
#                        an install that predates .ratchet-manifest
#   --no-verify          skip install.sh's post-apply hook suite
#   -h | --help
#
# Exit codes: 0 check/apply completed (read the report for CONFLICT count) ·
#             1 install.sh ran but its own verification failed ·
#             2 refused before changing anything
# =============================================================================
set -uo pipefail

RTU_VERSION="2.0.0"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  printf 'ratchet-update: cannot resolve my own directory\n' >&2; exit 2; }

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B="$(printf '\033[1m')"; C_R="$(printf '\033[31m')"; C_Y="$(printf '\033[33m')"; C_0="$(printf '\033[0m')"
else C_B=""; C_R=""; C_Y=""; C_0=""; fi
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%supdate refused:%s %s\n\n' "$C_R" "$C_0" "$*" >&2; exit 2; }
usage(){ awk 'NR>1{if($0!~/^#/)exit; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

MODE="check"; TARGET=""; FROM=""; DRY_RUN=0; ASSUME_YES=0; ALLOW_DOWNGRADE=0
ADOPT_BASELINE=0; RUN_VERIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;                --apply) MODE="apply" ;;
    --adopt-baseline) ADOPT_BASELINE=1 ;;
    --from) shift; [ $# -gt 0 ] || die "--from needs a path"; FROM="$1" ;;
    --from=*) FROM="${1#--from=}" ;;
    --target) shift; [ $# -gt 0 ] || die "--target needs a directory"; TARGET="$1" ;;
    --target=*) TARGET="${1#--target=}" ;;
    --dry-run|-n) DRY_RUN=1 ;;               --yes|-y) ASSUME_YES=1 ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1 ;;  --no-verify) RUN_VERIFY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# --- sha256 + python, reused for both the plain hash and the marker-canon one
PY=""
for c in "${RATCHET_PYTHON:-}" python3 python "py -3"; do
  [ -n "$c" ] || continue
  [ "$($c -c 'import sys;print(sys.version_info[0])' 2>/dev/null)" = "3" ] && { PY="$c"; break; }
done
SHA_TOOL=""
command -v sha256sum >/dev/null 2>&1 && SHA_TOOL="sha256sum"
[ -z "$SHA_TOOL" ] && command -v shasum >/dev/null 2>&1 && SHA_TOOL="shasum -a 256"
[ -n "$SHA_TOOL" ] || [ -n "$PY" ] || die "no usable checksum tool (sha256sum, shasum or python3).
  'has this harness file been edited locally?' is not decidable without one, and
  this updater will not guess before overwriting your control layer."
rtu_sha() { # <file> -> hex, empty on failure
  [ -f "$1" ] || return 1
  if [ -n "$SHA_TOOL" ]; then $SHA_TOOL "$1" 2>/dev/null | awk '{print $1}'
  else "$PY" -c 'import sys,hashlib
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
  fi
}
rtu_tmpl_sha() { # <source-template-file> -> hex of marker-canonicalised bytes
  [ -n "$PY" ] && [ -f "$1" ] || { rtu_sha "$1"; return; }
  "$PY" - "$1" <<'PYEOF' 2>/dev/null
import sys, re, hashlib
b = open(sys.argv[1], "rb").read().replace(b"\r\n", b"\n")
print(hashlib.sha256(re.sub(rb"\{\{[A-Z0-9_]+\}\}", b"<<RTMARK>>", b)).hexdigest())
PYEOF
}
rtu_semver_cmp() { # A B -> -1|0|1
  local a="${1#v}" b="${2#v}"; local -a A B
  IFS='.' read -r -a A <<<"${a%%-*}"; IFS='.' read -r -a B <<<"${b%%-*}"
  local i x y
  for i in 0 1 2; do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    case "$x" in *[!0-9]*|"") x=0;; esac; case "$y" in *[!0-9]*|"") y=0;; esac
    [ "$x" -lt "$y" ] && { printf -- '-1'; return; }
    [ "$x" -gt "$y" ] && { printf '1'; return; }
  done
  printf '0'
}

# ============================================================================
# CLASSIFICATION — exhaustive by construction. Default is USER: an
# unrecognised path is never touched. (RATCHET-DECISIONS-2026-08-23 §1.2 kept
# this function verbatim from the prior implementation — it was already right.)
# ============================================================================
rtu_classify() {
  case "$1" in
    .claude/settings.json) printf 'MERGED'; return ;;
    .claude/hooks/domain.config.sh|.claude/settings.json.bak-*|.claude/.backup-*|*.local-*|*.ratchet-merge)
      printf 'USER'; return ;;
    .claude/hooks/stack/*.sh|.claude/hooks/*.sh|.claude/hooks/*.py|.claude/agents/*.md|.claude/doctrine/*.md|CLAUDE.ratchet.md)
      printf 'HARNESS'; return ;;
  esac
  printf 'USER'
}
rtu_harness_paths() { # <root-dir> -> repo-relative HARNESS paths under it, on stdout
  local root="$1" d f rel
  for d in .claude/hooks .claude/hooks/stack .claude/agents .claude/doctrine; do
    [ -d "$root/$d" ] || continue
    for f in "$root/$d"/*; do
      [ -f "$f" ] || continue
      rel="$d/$(basename "$f")"
      [ "$(rtu_classify "$rel")" = "HARNESS" ] || continue
      printf '%s\n' "$rel"
    done
  done
  [ -f "$root/CLAUDE.ratchet.md" ] && printf '%s\n' "CLAUDE.ratchet.md"
}

head1 "Ratchet updater $RTU_VERSION"

# ============================================================================
# RESOLVE BUNDLE + TARGET
# ============================================================================
[ -n "$FROM" ] || FROM="$SRC_DIR"
BUNDLE_TMP=""; trap '[ -n "$BUNDLE_TMP" ] && rm -rf "$BUNDLE_TMP"' EXIT
if [ -d "$FROM" ]; then BUNDLE="$(cd "$FROM" && pwd)"
elif [ -f "$FROM" ] && [ "${FROM%.zip}" != "$FROM" ]; then
  command -v unzip >/dev/null 2>&1 || die "--from is a zip but 'unzip' is not on PATH."
  BUNDLE_TMP="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/rtu.$$")"; mkdir -p "$BUNDLE_TMP"
  unzip -q -o "$FROM" -d "$BUNDLE_TMP" || die "could not unzip $FROM"
  BUNDLE="$BUNDLE_TMP"
  [ -f "$BUNDLE/install.sh" ] || BUNDLE="$(dirname "$(find "$BUNDLE_TMP" -maxdepth 3 -name install.sh | head -1)")"
  [ -n "$BUNDLE" ] && [ -f "$BUNDLE/install.sh" ] || die "that zip is not a Ratchet bundle (no install.sh found)."
else die "--from path does not exist or is not a directory/.zip: $FROM"
fi
[ -f "$BUNDLE/install.sh" ] && [ -d "$BUNDLE/harness" ] || die "$BUNDLE is not a Ratchet bundle
  (needs install.sh and harness/). This updater deliberately contains no second
  copy of the install logic — it decides, install.sh writes."
HARNESS_SRC="$BUNDLE/harness"
BUNDLE_VERSION="$(sed -n 's/^RT_INSTALLER_VERSION="\([^"]*\)".*$/\1/p' "$BUNDLE/install.sh" | head -1)"
[ -n "$BUNDLE_VERSION" ] || die "cannot determine the bundle's version from install.sh."
ok "bundle:  $BUNDLE  (version $BUNDLE_VERSION)"

[ -n "$TARGET" ] || TARGET="$(pwd)"
[ -d "$TARGET" ] || die "--target does not exist: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
TROOT="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$TROOT" ] && [ "$TROOT" != "$TARGET" ] && TARGET="$TROOT"
[ -d "$TARGET/.claude/hooks" ] || die "$TARGET has no Ratchet install (.claude/hooks/ absent).
  To install for the first time:  bash \"$BUNDLE/install.sh\" --target \"$TARGET\""

VERSION_FILE="$TARGET/.claude/.ratchet-version"
MANIFEST="$TARGET/.claude/.ratchet-manifest"
INSTALL_STATE="$TARGET/.claude/.ratchet-install.json"
INSTALLED_VERSION="$([ -f "$VERSION_FILE" ] && head -1 "$VERSION_FILE" 2>/dev/null | tr -d '\r')"
[ -n "$INSTALLED_VERSION" ] || { INSTALLED_VERSION="0.0.0"; warn "no .claude/.ratchet-version — treating installed as 0.0.0."; }
ok "target:  $TARGET  (version $INSTALLED_VERSION)"

I_PROJECT=""; I_STACK=""; I_BASE=""; I_ESC=""
if [ -f "$INSTALL_STATE" ] && command -v jq >/dev/null 2>&1; then
  I_PROJECT="$(jq -r '.project_name    // empty' "$INSTALL_STATE" 2>/dev/null)"
  I_STACK="$(  jq -r '.stack           // empty' "$INSTALL_STATE" 2>/dev/null)"
  I_BASE="$(   jq -r '.base_branch     // empty' "$INSTALL_STATE" 2>/dev/null)"
  I_ESC="$(    jq -r '.escalation_mode // empty' "$INSTALL_STATE" 2>/dev/null)"
fi
# Reproduce the original install's answers exactly, as an array (never string-
# interpolated) so a project name with spaces or quotes cannot break the call.
INSTALL_ARGS=(--target "$TARGET" --force --quiet)
[ -n "$I_STACK" ]   && INSTALL_ARGS+=(--stack "$I_STACK")
[ -n "$I_PROJECT" ] && INSTALL_ARGS+=(--project-name "$I_PROJECT")
[ -n "$I_BASE" ]    && INSTALL_ARGS+=(--base-branch "$I_BASE")
[ -n "$I_ESC" ]     && INSTALL_ARGS+=(--escalation-mode "$I_ESC")

if [ "$ADOPT_BASELINE" = "1" ]; then
  head1 "Adopting the current tree as the checksum baseline"
  say "  Delegates to install.sh itself (the sole writer of .ratchet-manifest)."
  [ "$DRY_RUN" = "1" ] && { ok "DRY: would re-run install.sh to record the baseline"; exit 0; }
  bash "$BUNDLE/install.sh" "${INSTALL_ARGS[@]}" --no-verify \
    && ok "baseline recorded" || die "install.sh failed while adopting the baseline"
  exit 0
fi

VCMP="$(rtu_semver_cmp "$INSTALLED_VERSION" "$BUNDLE_VERSION")"
[ "$VCMP" = "1" ] && [ "$ALLOW_DOWNGRADE" != "1" ] && [ "$MODE" = "apply" ] && \
  die "bundle $BUNDLE_VERSION is OLDER than installed $INSTALLED_VERSION. Pass --allow-downgrade if you mean it."
[ -f "$TARGET/.pipeline/run-active" ] && [ "$MODE" = "apply" ] && [ "$DRY_RUN" != "1" ] && \
  die "a run is active (.pipeline/run-active). Swapping the gates mid-run means its
  second half is judged by different rules than its first. Archive the run first:
      .claude/hooks/gc-prune.sh archive <milestone>"

# ============================================================================
# CLASSIFY EVERY HARNESS FILE — the real 3-way compare
# ============================================================================
rtu_baseline() { # <rel> <col:1|2> -> value, empty if no baseline row
  [ -f "$MANIFEST" ] || return 1
  awk -v p="$1" -v c="$2" '$0!~/^#/ && $3==p {print (c==1?$1:$2); found=1} END{exit !found}' "$MANIFEST"
}

NEW=""; UPDATE=""; SAME=0; KEEP=""; CONFLICT=""; UNVERIFIED=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  dst="$TARGET/$rel"
  src="$HARNESS_SRC/$rel"
  [ "$rel" = "CLAUDE.ratchet.md" ] && src="$HARNESS_SRC/.claude/doctrine/CLAUDE.md"
  if [ ! -f "$dst" ]; then NEW="$NEW$rel"$'\n'; continue; fi
  old_inst="$(rtu_baseline "$rel" 1)"
  if [ -z "$old_inst" ]; then UNVERIFIED="$UNVERIFIED$rel"$'\n'; continue; fi
  old_tmpl="$(rtu_baseline "$rel" 2)"
  cur_inst="$(rtu_sha "$dst")"
  new_tmpl="$(rtu_tmpl_sha "$src")"
  edited=0;  [ "$cur_inst" = "$old_inst" ] || edited=1
  changed=1; [ -n "$old_tmpl" ] && [ "$old_tmpl" = "$new_tmpl" ] && changed=0
  if [ "$edited" = "0" ]; then
    [ "$changed" = "0" ] && SAME=$((SAME+1)) || UPDATE="$UPDATE$rel"$'\n'
  else
    [ "$changed" = "0" ] && KEEP="$KEEP$rel"$'\n' || CONFLICT="$CONFLICT$rel"$'\n'
  fi
done < <(rtu_harness_paths "$HARNESS_SRC")

ORPHAN=""
if [ -f "$MANIFEST" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$HARNESS_SRC/$rel" ] || [ "$rel" = "CLAUDE.ratchet.md" ] && continue
    [ -f "$TARGET/$rel" ] && ORPHAN="$ORPHAN$rel"$'\n'
  done < <(awk '$0!~/^#/{print $3}' "$MANIFEST")
fi

# ============================================================================
# REPORT
# ============================================================================
n() { printf '%s' "$1" | grep -c . 2>/dev/null; }
head1 "Plan: $INSTALLED_VERSION -> $BUNDLE_VERSION"
say "  NEW        $(n "$NEW")   UPDATE   $(n "$UPDATE")   SAME  $SAME"
say "  KEEP       $(n "$KEEP")   CONFLICT $(n "$CONFLICT")   UNVERIFIED $(n "$UNVERIFIED")   ORPHAN $(n "$ORPHAN")"
[ -n "$NEW" ]        && { head1 "NEW (not installed here yet)"; printf '%s' "$NEW" | sed 's/^/  /'; }
[ -n "$UPDATE" ]     && { head1 "UPDATE (clean upgrade, overwritten silently)"; printf '%s' "$UPDATE" | sed 's/^/  /'; }
[ -n "$KEEP" ]       && { head1 "KEEP (you edited it; upstream did not change it — left alone)"; printf '%s' "$KEEP" | sed 's/^/  /'; }
if [ -n "$CONFLICT" ]; then
  head1 "${C_Y}CONFLICT${C_0} (you edited it AND upstream changed it — the only interesting case)"
  printf '%s' "$CONFLICT" | sed 's/^/  /'
  say "  Each will get a sibling <path>.ratchet-merge holding the new version;"
  say "  your file is left untouched. Merge by hand."
fi
[ -n "$UNVERIFIED" ] && { head1 "UNVERIFIED (no baseline row — cannot prove local edits, treated as CONFLICT)"; printf '%s' "$UNVERIFIED" | sed 's/^/  /'; CONFLICT="$CONFLICT$UNVERIFIED"; }
[ -n "$ORPHAN" ]     && { head1 "ORPHAN (baseline knows it; the new bundle no longer ships it — left in place)"; printf '%s' "$ORPHAN" | sed 's/^/  /'; }
say ""
say "  MERGED  .claude/settings.json — install.sh unions permissions and re-wires hooks."
say "  USER    everything else, including every path not listed above."

if [ "$MODE" = "check" ]; then
  head1 "Check complete — nothing was written"
  say "  To apply:  $0 --apply --target \"$TARGET\" --from \"$FROM\""
  exit 0
fi

# ============================================================================
# APPLY — install.sh writes; this script snapshots KEEP/CONFLICT first and
# restores them after, since install.sh's copy has no concept of either.
# ============================================================================
if [ "$DRY_RUN" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
  if [ ! -t 0 ]; then die "no terminal to confirm on and --yes was not given."; fi
  printf '\n  %sProceed updating %s -> %s?%s  [y/N] ' "$C_B" "$INSTALLED_VERSION" "$BUNDLE_VERSION" "$C_0"
  read -r ans; case "$ans" in y|Y|yes|YES) ;; *) say "Aborted. Nothing was written."; exit 0 ;; esac
fi

SNAP="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/rtu-snap.$$")"; mkdir -p "$SNAP"
KEEP_CONFLICT="$KEEP$CONFLICT"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  mkdir -p "$SNAP/$(dirname "$rel")" 2>/dev/null
  cp -f "$TARGET/$rel" "$SNAP/$rel" 2>/dev/null
done <<<"$KEEP_CONFLICT"
[ -f "$MANIFEST" ] && cp -f "$MANIFEST" "$MANIFEST.pre-update" 2>/dev/null

[ "$RUN_VERIFY" != "1" ] && INSTALL_ARGS+=(--no-verify)
[ "$DRY_RUN" = "1" ]     && INSTALL_ARGS+=(--dry-run)
bash "$BUNDLE/install.sh" "${INSTALL_ARGS[@]}"
INSTALL_RC=$?

if [ "$DRY_RUN" != "1" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if printf '%s' "$CONFLICT" | grep -qx "$rel"; then
      mv -f "$TARGET/$rel" "$TARGET/$rel.ratchet-merge" 2>/dev/null
      cp -f "$SNAP/$rel" "$TARGET/$rel" 2>/dev/null
    else
      cp -f "$SNAP/$rel" "$TARGET/$rel" 2>/dev/null
    fi
  done <<<"$KEEP_CONFLICT"

  # Fix up the manifest install.sh just wrote: a KEEP path's installed-hash
  # must reflect the restored (user's) bytes, not what install.sh wrote before
  # we restored over it; a CONFLICT path's whole row reverts to pre-update, so
  # an unresolved conflict keeps showing up on the next run instead of
  # silently clearing.
  if [ -n "$PY" ] && [ -f "$MANIFEST" ] && [ -n "$KEEP_CONFLICT" ]; then
    "$PY" - "$MANIFEST" "${MANIFEST}.pre-update" "$TARGET" <<PYEOF 2>/dev/null
import sys
cur_path, old_path, target = sys.argv[1], sys.argv[2], sys.argv[3]
keep = """$KEEP""".splitlines()
conflict = """$CONFLICT""".splitlines()

def rows(p):
    out = {}
    try:
        for ln in open(p, encoding="utf-8"):
            parts = ln.rstrip("\n").split("  ")
            if len(parts) == 3:
                out[parts[2]] = ln.rstrip("\n")
    except OSError:
        pass
    return out

cur = rows(cur_path)
old = rows(old_path) if old_path else {}
for rel in conflict:
    if rel in old:
        cur[rel] = old[rel]
for rel in keep:
    if rel not in cur:
        continue
    h1, h2, path = cur[rel].split("  ")
    try:
        import hashlib
        newh = hashlib.sha256(open(target + "/" + rel, "rb").read()).hexdigest()
        cur[rel] = "  ".join([newh, h2, path])
    except OSError:
        pass

header = [ln for ln in open(cur_path, encoding="utf-8") if ln.startswith("#")]
open(cur_path, "w", encoding="utf-8").writelines(header + [cur[p] + "\n" for p in cur])
PYEOF
  elif [ -n "$KEEP_CONFLICT" ]; then
    warn "no python3 — the manifest for $(n "$KEEP_CONFLICT") KEEP/CONFLICT path(s) may be"
    say "        stale until the next update. Files on disk are correct either way."
  fi
  rm -f "${MANIFEST}.pre-update" 2>/dev/null
fi
rm -rf "$SNAP" 2>/dev/null

head1 "Applied"
[ -n "$CONFLICT" ] && warn "$(n "$CONFLICT") conflict(s) need manual merging (*.ratchet-merge)."
say "  install.sh exit code: $INSTALL_RC"
exit "$INSTALL_RC"
