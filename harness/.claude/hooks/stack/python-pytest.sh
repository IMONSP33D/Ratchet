#!/usr/bin/env bash
# stack/python-pytest.sh - STACK PACK (reference implementation), CONTRACT SS2.3.
# HUMANS: edit this file only to re-bind commands to your project's runner. It is the ONLY place
# that knows how to run this project's tests; no gate may hardcode a test command.
# ------------------------------------------------------------------------------------------------
# The stack pack is a pure binding: it defines strings, runs nothing. Consumers execute them with
# `bash -c "$CMD"` (or `eval`), so a command may contain pipes and flags but must not depend on
# the caller's shell functions.
#
# Commands that take an argument document it as $1 and are executed as: bash -c "$CMD" _ "<arg>".
#   SCOPED_TEST_CMD "$1" = scope selector (a pytest node id / -k expression / path)
#   RED_TEST_CMD    "$1" = same selector, run so a FAILING scope exits non-zero
#   COLLECT_TESTS_CMD "$1" = selector; must print test ids one per line on stdout
#   FORMAT_CMD      "$1" = one file path
# An EMPTY command string means "this project has no such gate": the gate SKIPs with a loud notice.
#
# Interpreter binding: hooks resolve python once via rt_pick_py (CONTRACT SS4.1) and export RT_PY.
# hooklib calls stack_rebind() after that, so these strings pick up the probed interpreter instead
# of assuming `python3` exists on PATH (it does not, on many Windows hosts).
# ------------------------------------------------------------------------------------------------

STACK_NAME="${STACK_NAME:-python-pytest}"

# Runner prefix: uv when the project uses it (it pins the interpreter for us), else the probed
# interpreter, else a bare python3 that stack_rebind will replace.
_rt_py_runner() {
  if [ -f "pyproject.toml" ] && command -v uv >/dev/null 2>&1; then
    printf '%s' "uv run"
  elif [ -n "${RT_PY:-}" ]; then
    printf '%s' "$RT_PY -m"
  elif [ -n "${RATCHET_PYTHON:-}" ]; then
    printf '%s' "$RATCHET_PYTHON -m"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "python3 -m"
  else
    printf '%s' "python -m"
  fi
}

# `make verify` is the universal deterministic gate when the project defines one; otherwise we
# compose an equivalent chain so a fresh project is not gate-less on day one.
_rt_default_verify() {
  local r="$1"
  if [ -f "Makefile" ] && grep -qs '^verify:' Makefile; then
    printf '%s' "make verify"
  else
    printf '%s' "$r pytest -q"
  fi
}

stack_rebind() {
  local r; r="$(_rt_py_runner)"
  VERIFY_CMD="${RATCHET_VERIFY_CMD:-$(_rt_default_verify "$r")}"
  FAST_TEST_CMD="${RATCHET_FAST_TEST_CMD:-$r pytest -q -x --no-header -p no:cacheprovider}"
  SCOPED_TEST_CMD="${RATCHET_SCOPED_TEST_CMD:-$r pytest -q --no-header -p no:cacheprovider \"\$1\"}"
  RED_TEST_CMD="${RATCHET_RED_TEST_CMD:-$r pytest -q --no-header -p no:cacheprovider \"\$1\"}"
  COLLECT_TESTS_CMD="${RATCHET_COLLECT_TESTS_CMD:-$r pytest -q --collect-only --no-header -p no:cacheprovider \"\$1\"}"
  SECRETS_SCAN_CMD="${RATCHET_SECRETS_SCAN_CMD:-}"
  DEP_AUDIT_CMD="${RATCHET_DEP_AUDIT_CMD:-}"
  FORMAT_CMD="${RATCHET_FORMAT_CMD:-}"
  if command -v gitleaks >/dev/null 2>&1; then
    SECRETS_SCAN_CMD="${RATCHET_SECRETS_SCAN_CMD:-gitleaks detect --no-banner --redact --exit-code 1}"
  fi
  if command -v pip-audit >/dev/null 2>&1 || [ -f "pyproject.toml" ]; then
    DEP_AUDIT_CMD="${RATCHET_DEP_AUDIT_CMD:-$r pip_audit}"
  fi
  if command -v ruff >/dev/null 2>&1; then
    FORMAT_CMD="${RATCHET_FORMAT_CMD:-ruff format -- \"\$1\"}"
  fi
}
stack_rebind

# --- classification regexes (egrep / grep -E syntax, matched against repo-relative POSIX paths) ---
TEST_PATH_REGEX="${TEST_PATH_REGEX:-(^|/)tests?/|(^|/)test_[^/]*\.py$|_test\.py$}"
TEST_SURFACE_REGEX="${TEST_SURFACE_REGEX:-(^|/)conftest\.py$|(^|/)pytest\.ini$|(^|/)tox\.ini$|(^|/)setup\.cfg$|(^|/)pyproject\.toml$|(^|/)tests?/(fixtures?|factories)/}"

# How a failing test renders in this runner's output (used to summarise a red/verify tail).
FAILURE_LINE_REGEX="${FAILURE_LINE_REGEX:-^(FAILED|ERROR)[[:space:]]|^E[[:space:]]+|[0-9]+ failed}"

FORMAT_EXTENSIONS="${FORMAT_EXTENSIONS:-py pyi}"

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then
  printf 'stack/%s selftest\n' "$STACK_NAME"
  for _v in STACK_NAME VERIFY_CMD FAST_TEST_CMD SCOPED_TEST_CMD RED_TEST_CMD COLLECT_TESTS_CMD \
            SECRETS_SCAN_CMD DEP_AUDIT_CMD FORMAT_CMD FORMAT_EXTENSIONS TEST_PATH_REGEX \
            TEST_SURFACE_REGEX FAILURE_LINE_REGEX; do
    eval "_val=\${$_v-__UNSET__}"
    [ "$_val" = "__UNSET__" ] && { printf '  FAIL: %s undefined\n' "$_v" >&2; exit 1; }
    printf '  %-20s %s\n' "$_v" "${_val:-(empty - gate SKIPs)}"
  done
  printf 'tests/test_a.py\nsrc/a.py\n' | grep -E "$TEST_PATH_REGEX" >/dev/null || {
    printf '  FAIL: TEST_PATH_REGEX did not match tests/test_a.py\n' >&2; exit 1; }
  printf '  OK\n'
  exit 0
fi
