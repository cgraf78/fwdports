#!/usr/bin/env bash
# Generation-owned launcher for built-in transports. The controller passes
# only stable file paths; this wrapper owns one direct child so tmux HUP can be
# converted into a catchable TERM and the transport is always reaped.

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

# Keep one foreground supervisor for every built-in transport. tmux tears a
# pane down with HUP, but autossh may deliberately ignore HUP while its SSH
# child remains alive. Converting every catchable shutdown to TERM and reaping
# the direct child prevents a failed startup rollback from orphaning a tunnel.
child=
signal_status=0

stop_child() {
  [[ -n ${child:-} ]] || return 0
  kill -TERM "$child" 2>/dev/null || true
}
on_hup() {
  signal_status=129
  stop_child
}
on_int() {
  signal_status=130
  stop_child
}
on_term() {
  signal_status=143
  stop_child
}
cleanup_child() {
  stop_child
  [[ -z ${child:-} ]] || wait "$child" 2>/dev/null || true
}
trap on_hup HUP
trap on_int INT
trap on_term TERM
trap cleanup_child EXIT

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
      wait "$child"
      status=$?
      # A signal trap may interrupt wait before the child has actually been
      # collected.  The second wait is harmless if it was already reaped and
      # prevents zombies on the cancellation path.
      wait "$child" 2>/dev/null || true
      child=
      [[ $signal_status -eq 0 ]] || exit "$signal_status"
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
    wait "$child"
    status=$?
    # A signal can interrupt wait before the child has finished handling TERM.
    # Reap it before exposing the signal-derived wrapper status to tmux.
    wait "$child" 2>/dev/null || true
    child=
    [[ $signal_status -eq 0 ]] || exit "$signal_status"
    exit "$status"
    ;;
  et | ettun)
    # ET and ettun own reconnect behavior inside one foreground process. Adding the
    # direct-SSH retry loop here would create competing policies and could
    # repeatedly prompt for authentication after a deterministic ET failure.
    gate=$runtime/$kind-gate
    "$gate" &
    child=$!
    wait "$child"
    status=$?
    wait "$child" 2>/dev/null || true
    child=
    [[ $signal_status -eq 0 ]] || exit "$signal_status"
    exit "$status"
    ;;
esac
