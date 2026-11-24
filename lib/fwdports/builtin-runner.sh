#!/usr/bin/env bash
# Generation-owned launcher for built-in transports. The controller passes
# only stable file paths. It owns and reaps one direct child where fwdports owns
# supervision; ettun instead owns its terminal process groups and signal tree.

set -u

runtime=${1:-}
[[ $runtime == /* && -d $runtime && ! -L $runtime ]] || exit 64

kind=$(<"$runtime/driver-kind") || exit 70
argv=()
target=
case "$kind" in
  ssh | autossh)
    target=$(<"$runtime/ssh-target") || exit 70
    while IFS= read -r element || [[ -n $element ]]; do
      [[ -n $element && $element != *$'\t'* && $element != *$'\r'* ]] ||
        exit 70
      argv+=("$element")
    done <"$runtime/ssh-argv"
    [[ -n ${argv[0]+set} ]] || exit 70
    ;;
  et)
    [[ -f $runtime/et-gate && -x $runtime/et-gate &&
      ! -L $runtime/et-gate ]] || exit 70
    ;;
  ettun)
    [[ -f $runtime/ettun-gate && -x $runtime/ettun-gate &&
      ! -L $runtime/ettun-gate ]] || exit 70
    ;;
  *)
    printf 'fwdports: invalid built-in driver snapshot\n' >&2
    exit 70
    ;;
esac

# Keep one foreground process for every built-in transport. tmux tears a pane
# down with HUP, but autossh may deliberately ignore HUP while its SSH child
# remains alive. Drivers supervised here get catchable shutdown converted to
# TERM and their direct child reaped. ettun owns that cleanup itself.
child=
signal_status=0
pending_stop=0

stop_child() {
  [[ -n ${child:-} ]] || return 0
  kill -TERM "$child" 2>/dev/null || true
}
request_stop() {
  signal_status=$1
  if [[ -z $child ]]; then
    pending_stop=1
  else
    pending_stop=0
    stop_child
  fi
}
cleanup_child() {
  stop_child
  [[ -z ${child:-} ]] || wait "$child" 2>/dev/null || true
}
trap 'request_stop 129' HUP
trap 'request_stop 130' INT
trap 'request_stop 143' TERM
trap cleanup_child EXIT

wait_child() {
  local status=0
  # Bash can run a signal trap after the fork and before the caller stores
  # $!. Deliver that stop once the runner has the child's exact PID.
  if ((pending_stop)); then
    pending_stop=0
    stop_child
  fi
  wait "$child" || status=$?
  # A trap can interrupt wait before the child has actually been collected.
  wait "$child" 2>/dev/null || true
  child=
  [[ $signal_status -eq 0 ]] || exit "$signal_status"
  return "$status"
}

case "$kind" in
  ssh)
    RUNNER_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
      exit 70
    # shellcheck disable=SC1091
    source "$RUNNER_DIR/health.sh"
    failures=0

    while :; do
      started=$SECONDS
      "$runtime/ssh-gate" "${argv[@]}" "$target" &
      child=$!
      status=0
      wait_child || status=$?
      # Exit 78 is the generation gate's explicit binary/config drift marker.
      # Retrying it would spin forever and could mask a changed trust input.
      [[ $status -ne 78 ]] || exit 78
      elapsed=$((SECONDS - started))
      if [[ $elapsed -ge 60 ]]; then
        failures=0
      else
        failures=$((failures + 1))
      fi
      delay=$(fwdports_backoff_for_failures "$((failures - 1))") || exit 70
      sleep "$delay"
      [[ $signal_status -eq 0 ]] || exit "$signal_status"
    done
    ;;
  autossh)
    autossh_path=$(LC_ALL=C sed -n 's/^path\t//p' \
      "$runtime/autossh-source") || exit 70
    [[ -n $autossh_path && -x $autossh_path ]] || exit 70
    # Autossh is explicitly selected, never an implicit upgrade from ssh.
    # Reset every ambient control knob that could daemonize it, change retry
    # policy, or write outside generation state.  AUTOSSH_PATH makes each
    # child pass through the same immutable SSH identity/config drift gate.
    unset AUTOSSH_MAXSTART AUTOSSH_MAXLIFETIME AUTOSSH_PIDFILE AUTOSSH_POLL
    unset AUTOSSH_FIRST_POLL AUTOSSH_LOGFILE AUTOSSH_LOGLEVEL AUTOSSH_MESSAGE
    unset AUTOSSH_DEBUG
    AUTOSSH_GATETIME=0
    AUTOSSH_PORT=0
    AUTOSSH_PATH=$runtime/ssh-gate
    export AUTOSSH_GATETIME AUTOSSH_PORT AUTOSSH_PATH
    "$autossh_path" -M 0 "${argv[@]}" "$target" &
    child=$!
    wait_child
    exit "$?"
    ;;
  et)
    # ET owns reconnect behavior inside one foreground process. Adding the
    # direct-SSH retry loop here would create competing policies.
    gate=$runtime/et-gate
    "$gate" <&0 &
    child=$!
    wait_child
    exit "$?"
    ;;
  ettun)
    # ettun owns reconnects, nested foreground process groups, and catchable
    # signal cleanup. A non-job-control Bash supervisor would start an async
    # gate with INT ignored, preventing terminal Ctrl-C from reaching those
    # groups. Preserve the pane PID and default signal dispositions by replacing
    # the runner after validation instead of creating another supervisor layer.
    exec "$runtime/ettun-gate" <&0
    ;;
esac
