#!/usr/bin/env bash
# stack/generic.sh - STACK PACK for docs-only or exotic projects, CONTRACT SS2.3.
# HUMANS: this pack binds NO commands on purpose. If your project has a test runner, copy
# stack/python-pytest.sh instead and re-bind it - do not add commands here.
# ------------------------------------------------------------------------------------------------
# Every command string is empty. That is a contract, not an omission: a gate that needs a command
# it does not have must SKIP LOUDLY (print the notice below to stderr, record a skip, and let the
# run continue) rather than fail the run or - far worse - silently pass.
#
# Read the distinction carefully, because it is the one place the harness deliberately does NOT
# fail closed:
#   * A gate whose COMMAND IS MISSING has nothing to measure. It SKIPs, loudly, every time, and
#     the skip is visible in the events log and the ship report.
#   * A gate whose command EXISTS and FAILS blocks, as always.
#   * A SECURITY decision never skips. Secrets, the governing corpus, the control set and the ship
#     consent check do not consult the stack pack at all - they hold on every stack, including
#     this one.
# So: no test runner means no test evidence, and a milestone whose WIN rows need test evidence
# cannot close on this pack. That is the correct outcome and it is visible, which is the point.
# ------------------------------------------------------------------------------------------------

STACK_NAME="${STACK_NAME:-generic}"

# The exact text a gate should print when it skips for want of a command. Consumers use it as:
#   [ -n "$VERIFY_CMD" ] || { printf '%s\n' "${STACK_SKIP_NOTICE//<gate>/verify}" >&2; skip; }
STACK_SKIP_NOTICE="${STACK_SKIP_NOTICE:-ratchet: SKIPPED <gate> - stack pack '${STACK_NAME}' binds no command for it. \
This gate measured NOTHING. Do not read its absence as a pass.}"

VERIFY_CMD="${VERIFY_CMD:-}"
FAST_TEST_CMD="${FAST_TEST_CMD:-}"
SCOPED_TEST_CMD="${SCOPED_TEST_CMD:-}"
RED_TEST_CMD="${RED_TEST_CMD:-}"
COLLECT_TESTS_CMD="${COLLECT_TESTS_CMD:-}"
SECRETS_SCAN_CMD="${SECRETS_SCAN_CMD:-}"
DEP_AUDIT_CMD="${DEP_AUDIT_CMD:-}"
FORMAT_CMD="${FORMAT_CMD:-}"
FORMAT_EXTENSIONS="${FORMAT_EXTENSIONS:-}"

# A regex that matches nothing: `rt_is_test_path` returns false for every path, so no gate can
# mistake a source file for a test. (An empty regex would match EVERYTHING under grep -E.)
TEST_PATH_REGEX="${TEST_PATH_REGEX:-^\$a}"
TEST_SURFACE_REGEX="${TEST_SURFACE_REGEX:-^\$a}"
FAILURE_LINE_REGEX="${FAILURE_LINE_REGEX:-^\$a}"

# No-op so hooklib's post-probe rebind hook is safe to call on every pack.
stack_rebind() { :; }

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  printf 'stack/%s selftest\n' "$STACK_NAME"
  for _v in VERIFY_CMD FAST_TEST_CMD SCOPED_TEST_CMD RED_TEST_CMD COLLECT_TESTS_CMD \
            SECRETS_SCAN_CMD DEP_AUDIT_CMD FORMAT_CMD FORMAT_EXTENSIONS; do
    eval "_val=\${$_v-__UNSET__}"
    [ "$_val" = "__UNSET__" ] && { printf '  FAIL: %s undefined\n' "$_v" >&2; exit 1; }
    [ -n "$_val" ] && { printf '  FAIL: %s must be empty in the generic pack\n' "$_v" >&2; exit 1; }
  done
  # The never-match regexes must not match a plausible test path.
  if printf 'tests/test_a.py\n' | grep -E "$TEST_PATH_REGEX" >/dev/null 2>&1; then
    printf '  FAIL: TEST_PATH_REGEX matched something\n' >&2; exit 1
  fi
  printf '  all commands empty, regexes match nothing: OK\n'
  printf '  skip notice: %s\n' "${STACK_SKIP_NOTICE//<gate>/verify}"
  exit 0
fi
