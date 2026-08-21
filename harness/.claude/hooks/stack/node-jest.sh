#!/usr/bin/env bash
# stack/node-jest.sh - STACK PACK for npm + jest projects, CONTRACT SS2.3.
# HUMANS: edit this file only to re-bind commands to your project's runner. It is the ONLY place
# that knows how to run this project's tests.
# ------------------------------------------------------------------------------------------------
# Same interface as stack/python-pytest.sh - see that file's header for the calling convention
# ($1 argument passing, empty string = gate SKIPs). Nothing here runs at source time except the
# capability probes below.
#
# Runner choice: `npm run <script>` when package.json defines the script (it carries the project's
# own flags), else a direct `npx jest`. npx is used rather than a bare `jest` because a locally
# installed jest is not on PATH.
# ------------------------------------------------------------------------------------------------

STACK_NAME="${STACK_NAME:-node-jest}"

# Return 0 if package.json declares the named npm script.
_rt_npm_has_script() {
  [ -f package.json ] || return 1
  grep -Eq "\"$1\"[[:space:]]*:" package.json 2>/dev/null
}

stack_rebind() {
  local jest="npx --no-install jest"
  command -v npx >/dev/null 2>&1 || jest="jest"

  if _rt_npm_has_script verify; then
    VERIFY_CMD="${RATCHET_VERIFY_CMD:-npm run verify}"
  elif _rt_npm_has_script test; then
    VERIFY_CMD="${RATCHET_VERIFY_CMD:-npm test --silent}"
  else
    VERIFY_CMD="${RATCHET_VERIFY_CMD:-$jest --ci}"
  fi

  FAST_TEST_CMD="${RATCHET_FAST_TEST_CMD:-$jest --ci --bail --silent}"
  SCOPED_TEST_CMD="${RATCHET_SCOPED_TEST_CMD:-$jest --ci --silent \"\$1\"}"
  RED_TEST_CMD="${RATCHET_RED_TEST_CMD:-$jest --ci --silent \"\$1\"}"
  COLLECT_TESTS_CMD="${RATCHET_COLLECT_TESTS_CMD:-$jest --listTests \"\$1\"}"

  SECRETS_SCAN_CMD="${RATCHET_SECRETS_SCAN_CMD:-}"
  if command -v gitleaks >/dev/null 2>&1; then
    SECRETS_SCAN_CMD="${RATCHET_SECRETS_SCAN_CMD:-gitleaks detect --no-banner --redact --exit-code 1}"
  fi

  DEP_AUDIT_CMD="${RATCHET_DEP_AUDIT_CMD:-}"
  if command -v npm >/dev/null 2>&1; then
    DEP_AUDIT_CMD="${RATCHET_DEP_AUDIT_CMD:-npm audit --audit-level=high}"
  fi

  FORMAT_CMD="${RATCHET_FORMAT_CMD:-}"
  if [ -f package.json ] && grep -Eq '"prettier"' package.json 2>/dev/null; then
    FORMAT_CMD="${RATCHET_FORMAT_CMD:-npx --no-install prettier --write -- \"\$1\"}"
  fi
}
stack_rebind

TEST_PATH_REGEX="${TEST_PATH_REGEX:-(^|/)__tests__/|(^|/)tests?/|\.(test|spec)\.[cm]?[jt]sx?$}"
TEST_SURFACE_REGEX="${TEST_SURFACE_REGEX:-(^|/)jest\.config\.[cm]?[jt]s$|(^|/)jest\.setup\.[cm]?[jt]s$|(^|/)package\.json$|(^|/)__mocks__/|(^|/)tests?/fixtures?/}"

# jest prints "FAIL <path>" per failing file and a "Tests: N failed" summary. ASCII only on
# purpose: the tick/cross glyphs jest uses do not survive every Windows console code page.
FAILURE_LINE_REGEX="${FAILURE_LINE_REGEX:-^[[:space:]]*FAIL[[:space:]]|Tests:.*failed|^[[:space:]]*at Object}"

FORMAT_EXTENSIONS="${FORMAT_EXTENSIONS:-js jsx ts tsx mjs cjs}"

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  printf 'stack/%s selftest\n' "$STACK_NAME"
  for _v in STACK_NAME VERIFY_CMD FAST_TEST_CMD SCOPED_TEST_CMD RED_TEST_CMD COLLECT_TESTS_CMD \
            SECRETS_SCAN_CMD DEP_AUDIT_CMD FORMAT_CMD FORMAT_EXTENSIONS TEST_PATH_REGEX \
            TEST_SURFACE_REGEX FAILURE_LINE_REGEX; do
    eval "_val=\${$_v-__UNSET__}"
    [ "$_val" = "__UNSET__" ] && { printf '  FAIL: %s undefined\n' "$_v" >&2; exit 1; }
    printf '  %-20s %s\n' "$_v" "${_val:-(empty - gate SKIPs)}"
  done
  printf 'src/a.test.ts\n' | grep -E "$TEST_PATH_REGEX" >/dev/null || {
    printf '  FAIL: TEST_PATH_REGEX did not match src/a.test.ts\n' >&2; exit 1; }
  printf 'FAIL src/a.test.ts\n' | grep -E "$FAILURE_LINE_REGEX" >/dev/null || {
    printf '  FAIL: FAILURE_LINE_REGEX did not match a jest failure line\n' >&2; exit 1; }
  printf '  OK\n'
  exit 0
fi
