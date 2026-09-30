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

# Resolve tmux before suites can shadow PATH with fakes, so teardown talks to
# the same binary the fixtures used. Absence only matters once a socket exists.
_FWDPORTS_TEST_TMUX=${FWDPORTS_TEST_TMUX_BIN:-$(command -v tmux 2>/dev/null)}

_test_tmux() {
  local socket=$1
  shift
  TMUX='' TMUX_PANE='' "$_FWDPORTS_TEST_TMUX" -S "$socket" -f /dev/null "$@"
}

# Poll the given pane process groups until each is empty. A group ID stays
# reserved while any member lives; the window in which an emptied group's ID
# could be reused by an unrelated process is tiny next to PID wraparound.
_test_tmux_groups_gone() {
  local attempts=0 pid live
  while [[ $attempts -lt 200 ]]; do
    live=0
    for pid in "$@"; do
      kill -0 -- "-$pid" 2>/dev/null && live=1
    done
    [[ $live -eq 0 ]] && return 0
    sleep 0.01
    attempts=$((attempts + 1))
  done
  return 1
}

# Stop a test tmux server that still owns panes; fail when there is none.
# A server whose last session is already gone is exiting on its own, so it is
# not reported as a leak. kill-server alone only hangs up pane terminals, so
# fixtures and drivers that ignore HUP would outlive their server and keep
# running from a deleted root. Signal each pane's process group first (tmux
# makes every pane a session and group leader), escalate after a bounded wait,
# and only then stop the server. Descendants that leave the pane's group are
# the owning case's responsibility.
_stop_test_tmux_server() {
  local socket=$1 panes dead pid attempts=0
  local -a pids=()
  panes=$(_test_tmux "$socket" list-panes -a \
    -F '#{pane_dead} #{pane_pid}' 2>/dev/null) || return 1
  if [[ -z "$panes" ]]; then
    _test_tmux "$socket" kill-server >/dev/null 2>&1
    return 1
  fi
  while read -r dead pid; do
    [[ $dead == 0 && $pid =~ ^[0-9]+$ ]] || continue
    pids+=("$pid")
    kill -TERM -- "-$pid" 2>/dev/null
  done <<<"$panes"
  if ! _test_tmux_groups_gone ${pids[@]+"${pids[@]}"}; then
    for pid in ${pids[@]+"${pids[@]}"}; do
      kill -KILL -- "-$pid" 2>/dev/null
    done
    _test_tmux_groups_gone ${pids[@]+"${pids[@]}"}
  fi
  _test_tmux "$socket" kill-server >/dev/null 2>&1
  while _test_tmux "$socket" list-sessions >/dev/null 2>&1 &&
    [[ $attempts -lt 200 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  return 0
}

# The one teardown path for a suite's own tmux servers. Suites call this where
# their case is done with a server; it is quiet because stopping an owned
# server there is expected, not a leak. Cases may run under errexit, and the
# stop sequence expects some signals and probes to fail, so invoke it from an
# `||` list, where Bash suspends errexit for the whole function body.
kill_test_server() {
  [[ -n "$_FWDPORTS_TEST_TMUX" ]] || return 0
  _stop_test_tmux_server "$1" || :
}

# Stop every tmux server still listening under this suite's root and record
# each socket that had one, one per line, in _FWDPORTS_TEST_LEAKED. Suites own
# their servers, but a failed assertion, early return, or interrupt can skip a
# suite's own teardown; deleting the root afterwards would orphan the server
# with an unreachable socket. This runs in the calling shell rather than a
# command substitution because subshells reset caught signals to defaults,
# which would let a second interrupt abandon the teardown sweep.
_stop_test_tmux_servers() {
  local socket
  _FWDPORTS_TEST_LEAKED=
  [[ -n "$_FWDPORTS_TEST_TMUX" && -d "$_FWDPORTS_TEST_TMP_ROOT" ]] || return 0
  while IFS= read -r socket; do
    [[ -n "$socket" ]] || continue
    if _stop_test_tmux_server "$socket"; then
      _FWDPORTS_TEST_LEAKED=$_FWDPORTS_TEST_LEAKED$socket$'\n'
    fi
  done < <(find "$_FWDPORTS_TEST_TMP_ROOT" -type s -print 2>/dev/null)
  return 0
}

# Signal traps pass the conventional 128+N status. Inside a trap, `$?` is the
# status of the interrupted command, which would let a killed suite exit 0.
_cleanup_test_root() {
  local status=$? socket
  [[ -z "${1:-}" ]] || status=$1
  # Finish teardown even if another signal arrives: an abandoned teardown
  # recreates the orphaned-server leak it prevents. A no-op handler rather
  # than an ignored signal keeps child tmux clients interruptible, so a second
  # Ctrl-C can still break a client stuck on an unresponsive socket.
  trap - EXIT
  trap : HUP INT TERM
  set +e
  _stop_test_tmux_servers
  if [[ -n "$_FWDPORTS_TEST_LEAKED" ]]; then
    # A server outside any case, or one left by an interrupted case, is
    # still a leak: report it and never let the suite pass because of it.
    while IFS= read -r socket; do
      [[ -n "$socket" ]] || continue
      printf 'fwdports test: stopped leaked tmux server: %s\n' \
        "$socket" >&2
    done <<<"$_FWDPORTS_TEST_LEAKED"
    [[ $status -ne 0 ]] || status=1
  fi
  case "$_FWDPORTS_TEST_TMP_ROOT" in
    "$_FWDPORTS_TEST_TMP_BASE"/f.*)
      rm -rf -- "$_FWDPORTS_TEST_TMP_ROOT"
      ;;
  esac
  exit "$status"
}
trap _cleanup_test_root EXIT
trap '_cleanup_test_root 129' HUP
trap '_cleanup_test_root 130' INT
trap '_cleanup_test_root 143' TERM

run_case() {
  local name=$1 function_name=$2 callback_status socket
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
  # Attribute leaks to the case that made them. Stopping them here also keeps
  # a leaked fixture from perturbing timing or ownership in later cases.
  _stop_test_tmux_servers
  while IFS= read -r socket; do
    [[ -n "$socket" ]] || continue
    _fail "case leaked tmux server: $name ($socket)"
  done <<<"$_FWDPORTS_TEST_LEAKED"
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
