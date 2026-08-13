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
  IFS=$'\t' read -r phase desired _ _ _ <<<"$control_record"
  [[ $phase == preparing && $desired == running ]] || {
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
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$ready"; then
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
        _ <<<"$control_record"
      if [[ $phase == running && $desired == running &&
        $controller_pid == "$$" && $controller_start == "$current_start" ]]; then
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
        _ <<<"$control_record"
      [[ ($phase == preparing || $phase == running) &&
        $desired == running ]] || {
        printf 'fwdports: controller boot was cancelled\n' >&2
        return 1
      }
      # Control and pointer are separate atomic files, so start must publish
      # them in some order. A matching running control while pending still
      # exists is a valid, read-only transition state; the controller keeps
      # waiting and gains mutation authority only after active also matches.
      if [[ $phase == running &&
        ($controller_pid != "$$" || $controller_start != "$current_start") ]]; then
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

_fwdports_controller_publish_probe() {
  local root=$1 generation=$2 digest=$3 probe=$4
  local candidate pointer control_record phase desired controller_pid
  local controller_start current_start status=0

  candidate=$(fwdports_lock_acquire "$root" 2>/dev/null) || return 75
  pointer=$(fwdports_pointer_read "$root" active) || status=$?
  if [[ $status -eq 0 &&
    $pointer != "$generation"$'\t'"$digest" ]]; then
    status=74
  fi
  if [[ $status -eq 0 ]]; then
    control_record=$(fwdports_control_read "$generation" "$digest") ||
      status=$?
  fi
  if [[ $status -eq 0 ]]; then
    IFS=$'\t' read -r phase desired controller_pid controller_start \
      _ <<<"$control_record"
    current_start=$(_fwdports_process_start_identity "$$") || status=$?
  fi
  if [[ $status -eq 0 && ($phase != running || $desired != running ||
    $controller_pid != "$$" || $controller_start != "$current_start") ]]; then
    status=74
  fi
  if [[ $status -eq 0 ]]; then
    fwdports_control_write "$generation" "$digest" running running \
      "$controller_pid" "$controller_start" "$probe" || status=$?
  fi
  fwdports_lock_release "$root" "$candidate" >/dev/null 2>&1 || {
    [[ $status -ne 0 ]] || status=74
  }
  return "$status"
}

fwdports_controller_run() {
  local root=$1 generation=$2 digest=$3 tick_seconds interval grace ticks=0
  local pointer control_record phase desired controller_pid controller_start
  local current_probe probe_result probe_status current_start

  tick_seconds=${FWDPORTS_CONTROLLER_TICK_SECONDS:-1}
  interval=${FWDPORTS_HEALTH_INTERVAL_TICKS:-30}
  grace=${FWDPORTS_HEALTH_STARTUP_GRACE_TICKS:-5}
  [[ $interval =~ ^[1-9][0-9]*$ && $grace =~ ^[0-9]+$ ]] || return 64
  fwdports_controller_wait_for_activation "$root" "$generation" "$digest" ||
    return $?
  current_start=$(_fwdports_process_start_identity "$$") || return 1

  while :; do
    pointer=$(fwdports_pointer_read "$root" active) || return 0
    [[ $pointer == "$generation"$'\t'"$digest" ]] || return 0
    control_record=$(fwdports_control_read "$generation" "$digest") ||
      return 0
    IFS=$'\t' read -r phase desired controller_pid controller_start \
      current_probe <<<"$control_record"
    [[ $phase == running && $desired == running ]] || return 0
    [[ $controller_pid == "$$" && $controller_start == "$current_start" ]] ||
      return 74

    ticks=$((ticks + 1))
    if [[ $ticks -ge $grace && $(((ticks - grace) % interval)) -eq 0 ]]; then
      probe_result=$(fwdports_health_probe "$generation/manifest")
      probe_status=$?
      case "$probe_status:$probe_result" in
        0:passing | 1:failing | 2:none) ;;
        *) return 74 ;;
      esac
      # A foreground user operation may briefly own the lifecycle lock.  A
      # health observation can wait for the next tick; it must never interfere
      # with start/stop merely to publish telemetry.
      # Publishing an unchanged observation only churns the control inode and
      # briefly contends with foreground start/stop for no semantic gain.
      # Keep telemetry edge-triggered so a fast test interval—and eventually a
      # slow real probe—cannot starve a user lifecycle operation.
      if [[ $probe_result != "$current_probe" ]]; then
        _fwdports_controller_publish_probe "$root" "$generation" "$digest" \
          "$probe_result"
        probe_status=$?
        [[ $probe_status -eq 0 || $probe_status -eq 75 ]] || return 74
      fi
    fi
    sleep "$tick_seconds"
  done
}

_fwdports_manifest_driver_for_leg() {
  local manifest=$1 wanted_leg=$2 kind leg driver _

  while IFS=$'\t' read -r kind leg driver _ || [[ -n ${kind:-} ]]; do
    if [[ $kind == leg && $leg == "$wanted_leg" ]]; then
      printf '%s\n' "$driver"
      return 0
    fi
  done <"$manifest"
  return 1
}

fwdports_status() {
  local root=$1 tmux_path=$2 socket=$3 session_name=$4 pointer generation digest
  local control_record phase desired controller_pid controller_start probe
  local current_start evidence found=0 verify_status all_live=1
  local controller_live=0 runtime leg driver snapshot record pane_id
  local driver_status

  if [[ -d "$root" && ! -L "$root" &&
    (-e "$root/active" || -L "$root/active") ]]; then
    pointer=$(fwdports_pointer_read "$root" active) || return 74
    IFS=$'\t' read -r generation digest <<<"$pointer"
    control_record=$(fwdports_control_read "$generation" "$digest") ||
      return 74
    IFS=$'\t' read -r phase desired controller_pid controller_start \
      probe <<<"$control_record"
    case "$phase" in
      stopping)
        printf 'stopping\n'
        return 0
        ;;
      preparing)
        printf 'starting\n'
        return 0
        ;;
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
        0)
          runtime=${evidence%/pane}
          leg=${runtime##*/}
          driver=$(_fwdports_manifest_driver_for_leg \
            "$generation/manifest" "$leg") || return 74
          if ! fwdports_driver_is_builtin "$driver"; then
            snapshot=$generation/drivers/$driver
            record=$(_fwdports_pane_evidence_read "$generation" \
              "$digest" "$evidence") || return 74
            IFS=$'\t' read -r _ pane_id _ <<<"$record"
            # Tmux/process evidence proves that core still owns the pane,
            # not that a driver-specific transport inside it is usable.
            # ABI status 2 deliberately asks core to use that conservative
            # fallback; status 1 lets a driver report a dead transport
            # without granting the driver any signalling authority.
            if fwdports_driver_operation "$snapshot" is-live \
              "$generation/manifest" "$leg" "$runtime" "$pane_id"; then
              driver_status=0
            else
              driver_status=$?
            fi
            case "$driver_status" in
              0 | 2) ;;
              1) all_live=0 ;;
              *)
                printf 'fwdports: driver liveness check failed for %s\n' \
                  "$leg" >&2
                return 74
                ;;
            esac
          fi
          ;;
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
    return 0
  fi

  if [[ -d "$root" && ! -L "$root" &&
    (-e "$root/pending" || -L "$root/pending") ]]; then
    pointer=$(fwdports_pointer_read "$root" pending) || return 74
    IFS=$'\t' read -r generation digest <<<"$pointer"
    control_record=$(fwdports_control_read "$generation" "$digest") ||
      return 74
    IFS=$'\t' read -r phase desired _ _ _ <<<"$control_record"
    case "$phase" in
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

_fwdports_cleanup_generation_drivers() {
  local generation=$1 digest=$2 kind leg driver _ runtime snapshot evidence
  local record pane_id='' index
  local -a legs=() drivers=()

  while IFS=$'\t' read -r kind leg driver _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    legs+=("$leg")
    drivers+=("$driver")
  done <"$generation/manifest"
  [[ -n ${legs[0]+set} ]] || return 0
  # Cleanup unwinds preparation order.  Drivers may deliberately layer one
  # transport over another, so reversing declaration order is the only
  # predictable contract and mirrors ordinary stack unwinding.
  for ((index = ${#legs[@]} - 1; index >= 0; index--)); do
    leg=${legs[index]}
    driver=${drivers[index]}
    fwdports_driver_is_builtin "$driver" && continue
    runtime=$generation/legs/$leg
    snapshot=$generation/drivers/$driver
    [[ -x $snapshot && -f $snapshot && ! -L $snapshot &&
      -d $runtime && ! -L $runtime ]] || continue
    evidence=$runtime/pane
    pane_id=
    if [[ -f $evidence && ! -L $evidence ]]; then
      record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
        "$evidence") || record=
      [[ -z $record ]] || {
        record=${record#*$'\t'}
        pane_id=${record%%$'\t'*}
      }
    fi
    # Driver cleanup is advisory and never confers signal authority.  Core
    # retains that authority after its full prevalidation; a broken cleanup
    # hook must not strand an otherwise safely stoppable generation.
    fwdports_driver_operation "$snapshot" cleanup \
      "$generation/manifest" "$leg" "$runtime" "$pane_id" ||
      printf 'fwdports: driver cleanup failed for %s\n' "$leg" >&2
  done
}

_fwdports_stop_pane_state() {
  local tmux_path=$1 socket=$2 generation=$3 digest=$4 evidence=$5
  local strategy=${6:-group} verify_status record leader pgid scope_status

  case "$strategy" in
    group | ettun-session) ;;
    *) return 74 ;;
  esac

  if fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
    "$digest" "$evidence"; then
    # A valid pane leader alone is insufficient authority for a live cleanup
    # opportunity. Most drivers own one process group; ettun deliberately
    # creates worker groups, so its complete kernel process session is the
    # boundary.
    if [[ $strategy == ettun-session ]]; then
      _fwdports_verify_owned_session "$generation" "$digest" "$evidence" \
        >/dev/null || return 74
    else
      _fwdports_verify_owned_group "$generation" "$digest" "$evidence" \
        >/dev/null || return 74
    fi
    printf 'live\n'
    return 0
  else
    verify_status=$?
  fi
  case "$verify_status" in
    1)
      # A dead pane is safe to finish only when its complete recorded process
      # boundary is empty. If a survivor remains after its leader disappeared,
      # ownership is incomplete and automatic recovery must stop.
      record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
        "$evidence") || return 74
      IFS=$'\t' read -r _ _ leader _ _ _ pgid _ _ <<<"$record"
      if [[ $strategy == ettun-session ]]; then
        if _fwdports_process_session_live_records "$leader" "$evidence" \
          >/dev/null 2>&1; then
          printf 'fwdports: recorded leader is gone but its session remains\n' \
            >&2
          return 74
        else
          scope_status=$?
        fi
      else
        if _fwdports_process_group_live_records "$pgid" \
          >/dev/null 2>&1; then
          printf 'fwdports: recorded leader is gone but its group remains\n' \
            >&2
          return 74
        else
          scope_status=$?
        fi
      fi
      if [[ $scope_status -ne 1 ]]; then
        if [[ $strategy == ettun-session ]]; then
          printf 'fwdports: cannot inspect the recorded process session\n' >&2
        else
          printf 'fwdports: cannot inspect the recorded process group\n' >&2
        fi
        return 74
      fi
      printf 'dead\n'
      ;;
    *) return 74 ;;
  esac
}

_fwdports_stop_generation_locked() {
  local tmux_path=$1 socket=$2 root=$3 pointer_kind=$4 generation=$5
  local digest=$6 session_name=$7 attempts=$8 delay=$9
  local control_record phase desired controller_pid controller_start
  local probe evidence pane_state runtime leg driver strategy index
  local -a pane_evidence=() pane_strategies=()

  control_record=$(fwdports_control_read "$generation" "$digest") || return 74
  IFS=$'\t' read -r phase desired controller_pid controller_start probe \
    <<<"$control_record"
  if [[ $phase != stopping || $desired != stopped ]]; then
    # Commit stop intent before the first signal. A crash after this atomic
    # write is resumable; a crash before it leaves the running generation
    # untouched because recovery does not infer intent from an invocation.
    fwdports_control_write "$generation" "$digest" stopping stopped \
      "$controller_pid" "$controller_start" "$probe" || return 74
  fi

  # External drivers can hold an authenticated transport that is required to
  # retire remote resources gracefully. The later process-group TERM also
  # reaches that transport, so a cleanup hook invoked only afterward is too
  # late. Authenticate every recorded pane before granting the advisory hook
  # any lifecycle opportunity, and retain the exact evidence paths so a hook
  # cannot make a pane disappear from the second pass by removing its record.
  for evidence in "$generation"/legs/*/pane; do
    [[ -e "$evidence" || -L "$evidence" ]] || continue
    runtime=${evidence%/pane}
    leg=${runtime##*/}
    driver=$(_fwdports_manifest_driver_for_leg \
      "$generation/manifest" "$leg") || return 74
    if [[ $driver == ettun ]]; then
      strategy=ettun-session
    else
      strategy=group
    fi
    pane_evidence+=("$evidence")
    pane_strategies+=("$strategy")
    _fwdports_stop_pane_state "$tmux_path" "$socket" "$generation" \
      "$digest" "$evidence" "$strategy" >/dev/null || return 74
  done

  # Cleanup is deliberately idempotent in the driver contract. The live pass
  # lets a driver use its already-authenticated channel; the final pass below
  # removes local residue after core has stopped every owned process. A crash
  # between them is safe because committed stop intent makes recovery repeat
  # both passes.
  _fwdports_cleanup_generation_drivers "$generation" "$digest"

  # Bash 3.2 treats the length of an empty nounset array as unbound. Iterate
  # through the safely guarded evidence expansion and use the explicit index
  # only after the loop has proved that the parallel arrays contain an entry.
  index=0
  for evidence in ${pane_evidence[@]+"${pane_evidence[@]}"}; do
    strategy=${pane_strategies[index]}
    pane_state=$(_fwdports_stop_pane_state "$tmux_path" "$socket" \
      "$generation" "$digest" "$evidence" "$strategy") || return 74
    case "$pane_state" in
      live)
        fwdports_tmux_terminate_pane "$tmux_path" "$socket" "$root" \
          "$pointer_kind" "$generation" "$digest" "$evidence" \
          "$attempts" "$delay" "$strategy" >/dev/null || return 74
        ;;
      dead) ;;
      *) return 74 ;;
    esac
    index=$((index + 1))
  done
  _fwdports_cleanup_generation_drivers "$generation" "$digest"
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
    IFS=$'\t' read -r phase desired _ _ _ <<<"$control_record"
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
  # shellcheck disable=SC1091
  source "$script_dir/tmux.sh"
  # shellcheck disable=SC1091
  source "$script_dir/driver-api.sh"
  # shellcheck disable=SC1091
  source "$script_dir/health.sh"
  case "$command" in
    wait-for-activation)
      [[ $# -eq 3 ]] || {
        printf 'usage: controller.sh wait-for-activation ROOT GENERATION DIGEST\n' \
          >&2
        return 64
      }
      fwdports_controller_wait_for_activation "$1" "$2" "$3"
      ;;
    run)
      [[ $# -eq 3 ]] || {
        printf 'usage: controller.sh run ROOT GENERATION DIGEST\n' >&2
        return 64
      }
      fwdports_controller_run "$1" "$2" "$3"
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
