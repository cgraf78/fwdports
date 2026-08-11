#!/usr/bin/env bash
# Minimal Bash 3.2-compatible behavior-test harness. Tests intentionally own
# their temporary roots so process, tmux, and filesystem assertions never use
# the developer's live HOME or runtime directories.

set -uo pipefail

# CI runners and callers can inherit a permissive umask.  The fixtures contain
# generated owner records and executable drivers, so make privacy the harness
# default instead of relying on every test to remember a chmod immediately.
umask 077

PASS=0
FAIL=0
RUN=0
CURRENT_TEST_CASE=

_pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

_fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$1" >&2
}

_assert_eq() {
  local description=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    _pass "$description"
  else
    _fail "$description (expected '$expected', got '$actual')"
  fi
}

_assert_ne() {
  local description=$1 unexpected=$2 actual=$3
  if [[ "$unexpected" != "$actual" ]]; then
    _pass "$description"
  else
    _fail "$description (unexpected '$unexpected')"
  fi
}

_assert_contains() {
  local description=$1 needle=$2 haystack=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$description"
  else
    _fail "$description (expected to contain '$needle')"
  fi
}

_assert_not_contains() {
  local description=$1 needle=$2 haystack=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    _pass "$description"
  else
    _fail "$description (unexpectedly contained '$needle')"
  fi
}

_assert_file() {
  local description=$1 path=$2
  if [[ -f "$path" && ! -L "$path" ]]; then
    _pass "$description"
  else
    _fail "$description (not a regular file: $path)"
  fi
}

_assert_not_exists() {
  local description=$1 path=$2
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    _pass "$description"
  else
    _fail "$description (path exists: $path)"
  fi
}

_assert_exit() {
  local description=$1 expected=$2 actual=$3
  if [[ "$expected" -eq "$actual" ]]; then
    _pass "$description"
  else
    _fail "$description (expected exit $expected, got $actual)"
  fi
}

_FWDPORTS_TEST_TMP_BASE=${TMPDIR:-/tmp}
[[ -d "$_FWDPORTS_TEST_TMP_BASE" ]] || {
  printf 'fwdports test: temporary base is not a directory: %s\n' \
    "$_FWDPORTS_TEST_TMP_BASE" >&2
  exit 1
}
# macOS exposes /var through a /private/var symlink, and TMPDIR commonly ends
# in a slash.  Resolve that spelling once so production path normalization and
# the harness agree about the same physical test root.
_FWDPORTS_TEST_TMP_BASE=$(cd -P -- "$_FWDPORTS_TEST_TMP_BASE" && pwd -P) || {
  printf 'fwdports test: cannot resolve temporary base\n' >&2
  exit 1
}
_FWDPORTS_TEST_TMP_ROOT=$(mktemp -d \
  "$_FWDPORTS_TEST_TMP_BASE/f.XXXXXX") || {
  printf 'fwdports test: cannot create temporary root\n' >&2
  exit 1
}
case "$_FWDPORTS_TEST_TMP_ROOT" in
  "$_FWDPORTS_TEST_TMP_BASE"/f.*) ;;
  *)
    printf 'fwdports test: unsafe temporary root: %s\n' \
      "$_FWDPORTS_TEST_TMP_ROOT" >&2
    exit 1
    ;;
esac
[[ -d "$_FWDPORTS_TEST_TMP_ROOT" && ! -L "$_FWDPORTS_TEST_TMP_ROOT" ]] || {
  printf 'fwdports test: temporary root is not a directory\n' >&2
  exit 1
}

_tmpdir() {
  local path
  # tmux sockets use a small sockaddr path on macOS. Keep both random
  # directory components short so physically canonical /private/var paths do
  # not make otherwise valid lifecycle tests exceed that operating-system ABI.
  path=$(mktemp -d "$_FWDPORTS_TEST_TMP_ROOT/s.XXXXXX") || {
    printf 'fwdports test: cannot create suite directory\n' >&2
    return 1
  }
  case "$path" in
    "$_FWDPORTS_TEST_TMP_ROOT"/s.*) ;;
    *)
      printf 'fwdports test: unsafe suite directory: %s\n' "$path" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$path"
}

_cleanup_test_root() {
  local status=$?
  trap - EXIT HUP INT TERM
  case "$_FWDPORTS_TEST_TMP_ROOT" in
    "$_FWDPORTS_TEST_TMP_BASE"/f.*)
      rm -rf -- "$_FWDPORTS_TEST_TMP_ROOT"
      ;;
  esac
  exit "$status"
}
trap _cleanup_test_root EXIT HUP INT TERM

run_case() {
  local name=$1 function_name=$2 callback_status
  if [[ -n "${TEST_CASE:-}" && "${TEST_CASE:-}" != "$name" ]]; then
    return 0
  fi
  RUN=$((RUN + 1))
  # Sourced suites inspect this value; standalone analysis cannot see them.
  # shellcheck disable=SC2034
  CURRENT_TEST_CASE=$name
  printf '=== %s ===\n' "$name"
  # Do not invoke the callback as an `if` condition: Bash suppresses errexit
  # throughout functions called from a conditional, which can let a failed
  # setup command fall through to a later successful command. Start each case
  # without inherited errexit, while allowing the callback to enable it when
  # that is part of the case's own failure contract.
  set +e
  "$function_name"
  callback_status=$?
  set +e
  if [[ $callback_status -ne 0 ]]; then
    # Setup helpers often return before reaching an explicit assertion. Treat
    # that as a failed case so an unavailable tmux socket or fixture cannot
    # produce a misleading all-green summary with zero useful coverage.
    _fail "case callback failed: $name"
  fi
}

_test_summary() {
  if [[ -n "${TEST_CASE:-}" && "$RUN" -eq 0 ]]; then
    _fail "unknown test case: ${TEST_CASE}"
  fi
  printf '%s\n' '================================'
  printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
  printf '%s\n' '================================'
  if [[ "$FAIL" -eq 0 ]]; then
    exit 0
  fi
  exit 1
}
