#!/usr/bin/env bash
# Controller boot handshake. The pre-activation process is intentionally
# powerless: it may publish only its generation-scoped readiness evidence and
# then waits for the lifecycle-lock holder to publish matching control and
# active-pointer state. This prevents a fast controller from repairing or
# mutating a generation that start has not yet committed.

_fwdports_controller_write_ready() {
  local root=$1 generation=$2 digest=$3 pointer control_record phase desired
  local controller_pid controller_start ready tmp old_umask

  pointer=$(fwdports_pointer_read "$root" pending) || return 1
  [[ $pointer == "$generation"$'\t'"$digest" ]] || {
    printf 'fwdports: pending generation changed before controller ready\n' >&2
    return 1
  }
  control_record=$(fwdports_control_read "$generation" "$digest") || return 1
  IFS=$'\t' read -r phase desired _ _ _ _ _ <<<"$control_record"
  [[ ($phase == preparing || $phase == starting) &&
    $desired == running ]] || {
    printf 'fwdports: controller cannot become ready in this phase\n' >&2
    return 1
  }
  controller_pid=$$
  controller_start=$(_fwdports_process_start_identity "$controller_pid") ||
    return 1
  ready=$generation/controller.ready
  [[ ! -e "$ready" && ! -L "$ready" ]] || {
    printf 'fwdports: controller readiness evidence already exists\n' >&2
    return 1
  }
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$generation/.controller.ready.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'version\t1\n'
    printf 'generation\t%s\n' "${generation##*/}"
    printf 'manifest-digest\t%s\n' "$digest"
    printf 'controller-pid\t%s\n' "$controller_pid"
    printf 'controller-start\t%s\n' "$controller_start"
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$ready";
  then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_controller_wait_for_activation() {
  local root=$1 generation=$2 digest=$3 tick_seconds max_ticks ticks=0
  local active pending control_record phase desired controller_pid
  local controller_start current_start

  tick_seconds=${FWDPORTS_CONTROLLER_TICK_SECONDS:-1}
  max_ticks=${FWDPORTS_CONTROLLER_MAX_TICKS:-0}
  [[ $tick_seconds =~ ^(0|0\.[0-9]+|[1-9][0-9]*(\.[0-9]+)?)$ &&
    $max_ticks =~ ^[0-9]+$ ]] || {
    printf 'fwdports: invalid controller timing configuration\n' >&2
    return 1
  }
  _fwdports_controller_write_ready "$root" "$generation" "$digest" ||
    return 1
  current_start=$(_fwdports_process_start_identity "$$") || return 1

  while :; do
    if [[ -e "$root/active" || -L "$root/active" ]]; then
      active=$(fwdports_pointer_read "$root" active) || return 1
      [[ $active == "$generation"$'\t'"$digest" ]] || {
        printf 'fwdports: another generation became active\n' >&2
        return 1
      }
      control_record=$(fwdports_control_read "$generation" "$digest") ||
        return 1
      IFS=$'\t' read -r phase desired controller_pid controller_start \
        _ _ _ <<<"$control_record"
      if [[ $phase == running && $desired == running &&
        $controller_pid == "$$" && $controller_start == "$current_start" ]];
      then
        printf 'activated\n'
        return 0
      fi
    else
      # Until publication, pending remains the sole authority. Rechecking it
      # on every condition tick makes cancellation immediate and ensures the
      # controller never waits on a path that has been repurposed.
      pending=$(fwdports_pointer_read "$root" pending) || return 1
      [[ $pending == "$generation"$'\t'"$digest" ]] || {
        printf 'fwdports: pending generation changed during controller boot\n' \
          >&2
        return 1
      }
      control_record=$(fwdports_control_read "$generation" "$digest") ||
        return 1
      IFS=$'\t' read -r phase desired controller_pid controller_start \
        _ _ _ <<<"$control_record"
      [[ ($phase == preparing || $phase == starting || $phase == running) &&
        $desired == running ]] || {
        printf 'fwdports: controller boot was cancelled\n' >&2
        return 1
      }
      # Control and pointer are separate atomic files, so start must publish
      # them in some order. A matching running control while pending still
      # exists is a valid, read-only transition state; the controller keeps
      # waiting and gains mutation authority only after active also matches.
      if [[ $phase == running &&
        ($controller_pid != "$$" || $controller_start != "$current_start") ]];
      then
        printf 'fwdports: running control names another controller\n' >&2
        return 1
      fi
    fi
    ticks=$((ticks + 1))
    if [[ $max_ticks -gt 0 && $ticks -ge $max_ticks ]]; then
      printf 'fwdports: controller activation timed out\n' >&2
      return 75
    fi
    sleep "$tick_seconds"
  done
}

fwdports_status() {
  local root=$1 tmux_path=$2 socket=$3 session_name=$4 pointer generation digest
  local control_record phase desired controller_pid controller_start failures
  local backoff probe current_start evidence found=0 verify_status all_live=1
  local controller_live=0

  if [[ -d "$root" && ! -L "$root" &&
    (-e "$root/active" || -L "$root/active") ]]; then
    pointer=$(fwdports_pointer_read "$root" active) || return 74
    IFS=$'\t' read -r generation digest <<<"$pointer"
    control_record=$(fwdports_control_read "$generation" "$digest") ||
      return 74
    IFS=$'\t' read -r phase desired controller_pid controller_start \
      failures backoff probe <<<"$control_record"
    case "$phase" in
      stopping) printf 'stopping\n'; return 0 ;;
      failed) printf 'failed\n'; return 0 ;;
      backoff) printf 'backoff\n'; return 0 ;;
      preparing | starting) printf 'starting\n'; return 0 ;;
      running) ;;
      *) return 74 ;;
    esac
    [[ $desired == running ]] || {
      printf 'stopping\n'
      return 0
    }

    if [[ $controller_pid =~ ^[0-9]+$ ]] &&
      kill -0 "$controller_pid" 2>/dev/null; then
      current_start=$(_fwdports_process_start_identity "$controller_pid") ||
        current_start=
      [[ $current_start == "$controller_start" ]] && controller_live=1
    fi

    for evidence in "$generation"/legs/*/pane; do
      [[ -e "$evidence" || -L "$evidence" ]] || continue
      found=1
      if fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
        "$digest" "$evidence"; then
        verify_status=0
      else
        verify_status=$?
      fi
      case "$verify_status" in
        0) ;;
        1) all_live=0 ;;
        *)
          printf 'fwdports: pane ownership cannot be verified\n' >&2
          return 74
          ;;
      esac
    done
    if [[ $found -eq 0 || $all_live -eq 0 ]]; then
      printf 'down\n'
      return 0
    fi
    if [[ $controller_live -eq 0 ]]; then
      printf 'controller-down\n'
      return 0
    fi
    case "$probe" in
      passing) printf 'healthy\n' ;;
      failing) printf 'degraded\n' ;;
      none | unknown) printf 'live/unverified\n' ;;
      *) return 74 ;;
    esac
    : "$failures" "$backoff"
    return 0
  fi

  if [[ -d "$root" && ! -L "$root" &&
    (-e "$root/pending" || -L "$root/pending") ]]; then
    pointer=$(fwdports_pointer_read "$root" pending) || return 74
    IFS=$'\t' read -r generation digest <<<"$pointer"
    control_record=$(fwdports_control_read "$generation" "$digest") ||
      return 74
    IFS=$'\t' read -r phase desired _ _ _ _ _ <<<"$control_record"
    case "$phase" in
      failed) printf 'failed\n' ;;
      stopping) printf 'stopping\n' ;;
      *) printf 'starting\n' ;;
    esac
    return 0
  fi

  # A matching name without an authenticated pointer is explicitly unowned.
  # Reporting it is safe; adopting or killing it based on the name would not
  # be. This check also makes a later start refusal actionable.
  if fwdports_tmux_session_named_exists "$tmux_path" "$socket" \
    "$session_name"; then
    printf 'unowned-session\n'
    return 1
  fi
  printf 'stopped\n'
}

_fwdports_stop_generation_locked() {
  local tmux_path=$1 socket=$2 root=$3 pointer_kind=$4 generation=$5
  local digest=$6 session_name=$7 attempts=$8 delay=$9
  local control_record phase desired controller_pid controller_start
  local failures backoff probe evidence verify_status record pgid

  control_record=$(fwdports_control_read "$generation" "$digest") || return 74
  IFS=$'\t' read -r phase desired controller_pid controller_start failures \
    backoff probe <<<"$control_record"
  if [[ $phase != stopping || $desired != stopped ]]; then
    # Commit stop intent before the first signal. A crash after this atomic
    # write is resumable; a crash before it leaves the running generation
    # untouched because recovery does not infer intent from an invocation.
    fwdports_control_write "$generation" "$digest" stopping stopped \
      "$controller_pid" "$controller_start" "$failures" "$backoff" \
      "$probe" || return 74
  fi

  for evidence in "$generation"/legs/*/pane; do
    [[ -e "$evidence" || -L "$evidence" ]] || continue
    if fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
      "$digest" "$evidence"; then
      verify_status=0
    else
      verify_status=$?
    fi
    case "$verify_status" in
      0)
        fwdports_tmux_terminate_pane "$tmux_path" "$socket" "$root" \
          "$pointer_kind" "$generation" "$digest" "$evidence" \
          "$attempts" "$delay" >/dev/null || return 74
        ;;
      1)
        # A dead pane is safe to finish only when its recorded group is also
        # empty. If a survivor remains after its leader disappeared, ownership
        # is incomplete and automatic recovery must stop.
        record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
          "$evidence") || return 74
        IFS=$'\t' read -r _ _ _ _ _ _ pgid _ _ <<<"$record"
        if _fwdports_process_group_records "$pgid" >/dev/null 2>&1; then
          printf 'fwdports: recorded leader is gone but its group remains\n' >&2
          return 74
        fi
        ;;
      *) return 74 ;;
    esac
  done
  fwdports_tmux_remove_generation_session "$tmux_path" "$socket" \
    "$generation" "$digest" "$session_name" || return 74
  fwdports_pointer_remove "$root" "$pointer_kind" "$generation" "$digest" ||
    return 74
  fwdports_generation_remove "$root" "$generation" "$digest" || return 74
}

_fwdports_recover_state_locked() {
  local tmux_path=$1 socket=$2 root=$3 session_name=$4 attempts=$5 delay=$6
  local active='' pending='' active_generation active_digest
  local pending_generation pending_digest control_record phase desired

  if [[ -e "$root/active" || -L "$root/active" ]]; then
    active=$(fwdports_pointer_read "$root" active) || return 74
    IFS=$'\t' read -r active_generation active_digest <<<"$active"
  fi
  if [[ -e "$root/pending" || -L "$root/pending" ]]; then
    pending=$(fwdports_pointer_read "$root" pending) || return 74
    IFS=$'\t' read -r pending_generation pending_digest <<<"$pending"
  fi

  if [[ -n $active && -n $pending ]]; then
    if [[ $active == "$pending" ]]; then
      # Active is authoritative once both records name the same immutable
      # generation. Pending is merely a crash remnant, not a second instance.
      fwdports_pointer_remove "$root" pending "$pending_generation" \
        "$pending_digest" || return 74
      pending=
    else
      _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
        pending "$pending_generation" "$pending_digest" "$session_name" \
        "$attempts" "$delay" || return 74
      printf 'pending-rolled-back\n'
      return 0
    fi
  elif [[ -z $active && -n $pending ]]; then
    _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
      pending "$pending_generation" "$pending_digest" "$session_name" \
      "$attempts" "$delay" || return 74
    printf 'pending-rolled-back\n'
    return 0
  fi

  if [[ -n $active ]]; then
    control_record=$(fwdports_control_read "$active_generation" \
      "$active_digest") || return 74
    IFS=$'\t' read -r phase desired _ _ _ _ _ <<<"$control_record"
    if [[ $phase == stopping && $desired == stopped ]]; then
      _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
        active "$active_generation" "$active_digest" "$session_name" \
        "$attempts" "$delay" || return 74
      printf 'stopped\n'
    else
      printf 'active\n'
    fi
    return 0
  fi

  if fwdports_tmux_session_named_exists "$tmux_path" "$socket" \
    "$session_name"; then
    printf 'unowned-session\n'
    return 1
  fi
  printf 'stopped\n'
}

fwdports_recover_state() {
  local tmux_path=$1 socket=$2 root=$3 session_name=$4 attempts=$5 delay=$6
  local candidate status release_status

  [[ -d "$root" && ! -L "$root" ]] || {
    if fwdports_tmux_session_named_exists "$tmux_path" "$socket" \
      "$session_name"; then
      printf 'unowned-session\n'
      return 1
    fi
    printf 'stopped\n'
    return 0
  }
  candidate=$(fwdports_lock_acquire "$root") || return $?
  _fwdports_recover_state_locked "$tmux_path" "$socket" "$root" \
    "$session_name" "$attempts" "$delay"
  status=$?
  fwdports_lock_release "$root" "$candidate"
  release_status=$?
  [[ $release_status -eq 0 ]] || return "$release_status"
  return "$status"
}

_fwdports_controller_main() {
  local command=${1:-} script_dir
  shift || true
  script_dir=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    return 1
  # The path is anchored to this checkout at runtime; ShellCheck cannot follow
  # a computed module path, while the inventory checks runtime.sh separately.
  # shellcheck disable=SC1091
  source "$script_dir/runtime.sh"
  case "$command" in
    wait-for-activation)
      [[ $# -eq 3 ]] || {
        printf 'usage: controller.sh wait-for-activation ROOT GENERATION DIGEST\n' \
          >&2
        return 64
      }
      fwdports_controller_wait_for_activation "$1" "$2" "$3"
      ;;
    *)
      printf 'fwdports: unknown controller operation\n' >&2
      return 64
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -u
  _fwdports_controller_main "$@"
  exit $?
fi
