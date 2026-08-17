#!/usr/bin/env bash
# Command orchestration for fwdports.
#
# The public executable stays intentionally small; this module composes the
# separately tested config, state, driver, tmux, and cleanup authorities.  It
# never launches an interpolated shell command.  Paths and process identities
# become cleanup authority only after their owning layer has authenticated
# them.

FWDPORTS_SESSION_NAME=fwdports

_fwdports_command_path() {
  local command_name=$1 path
  path=$(type -P -- "$command_name" 2>/dev/null) || return 1
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$PWD" "$path" ;;
  esac
}

_fwdports_config_root() {
  if [[ ${XDG_CONFIG_HOME:-} == /* ]]; then
    printf '%s/fwdports\n' "$XDG_CONFIG_HOME"
  else
    [[ ${HOME:-} == /* ]] || return 1
    printf '%s/.config/fwdports\n' "$HOME"
  fi
}

_fwdports_state_root_path() {
  if [[ ${XDG_STATE_HOME:-} == /* ]]; then
    printf '%s/fwdports\n' "$XDG_STATE_HOME"
  else
    [[ ${HOME:-} == /* ]] || return 1
    printf '%s/.local/state/fwdports\n' "$HOME"
  fi
}

_fwdports_tmux_socket() {
  local root=$1 runtime_parent old_umask

  if [[ -n ${FWDPORTS_TMUX_SOCKET:-} ]]; then
    [[ $FWDPORTS_TMUX_SOCKET == /* ]] || {
      printf 'fwdports: FWDPORTS_TMUX_SOCKET must be absolute\n' >&2
      return 1
    }
    printf '%s\n' "$FWDPORTS_TMUX_SOCKET"
    return 0
  fi
  if [[ ${XDG_RUNTIME_DIR:-} == /* && -d $XDG_RUNTIME_DIR &&
    ! -L $XDG_RUNTIME_DIR ]]; then
    runtime_parent=$XDG_RUNTIME_DIR/fwdports
  else
    runtime_parent=$root/runtime
  fi
  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$runtime_parent" || ! chmod 0700 "$runtime_parent"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  printf '%s/tmux.sock\n' "$runtime_parent"
}

_fwdports_desired_prepare() {
  local config=$1 profile=$2 workspace=$3 config_parent allowed_root=$4
  local snapshot=$workspace/tunnels.conf resolved=$workspace/resolved.conf

  config_parent=${config%/*}
  [[ $config_parent != "$config" && -d "$config_parent" ]] || {
    printf 'fwdports: config parent is unavailable: %s\n' "$config" >&2
    return 1
  }
  # Snapshot before parsing.  Dotfiles-managed symlinks remain supported, but
  # both the link and its canonical target must stay beneath the caller's
  # trusted home and keep trusted owner/mode metadata during the copy.
  fwdports_snapshot_trusted_file "$config" "$snapshot" "$config_parent" \
    file "$allowed_root" || return 1
  fwdports_config_resolve "$snapshot" "$profile" "$resolved" || return 1
  printf '%s\n' "$resolved"
}

_fwdports_manifest_matches_desired() {
  local generation=$1 resolved=$2 config_root=$3 allowed_root=$4
  local target_override=${5:-}
  local manifest=$generation/manifest manifest_records desired_records
  local kind leg driver source expected actual recorded_target

  recorded_target=$(LC_ALL=C sed -n '3s/^target\t//p' "$manifest") ||
    return 1
  [[ $recorded_target == "${target_override:-none}" ]] || return 1
  manifest_records=$(LC_ALL=C sed -n '4,$p' "$manifest") || return 1
  desired_records=$(LC_ALL=C sed -n '2,$p' "$resolved") || return 1
  [[ $manifest_records == "$desired_records" ]] || return 1

  # Config bytes are not the whole desired state for executable extensions.
  # Reconcile only when the currently configured driver still hashes to the
  # immutable generation snapshot; otherwise require explicit replacement.
  while IFS=$'\t' read -r kind leg driver _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    fwdports_driver_is_builtin "$driver" && continue
    expected=$(<"$generation/drivers/$driver.digest") || return 1
    source=$(fwdports_driver_discover "$config_root" "$driver" \
      "$allowed_root") || return 1
    actual=$(_fwdports_runtime_sha256_file "$source") || return 1
    [[ $actual == "$expected" ]] || return 1
    : "$leg"
  done <"$resolved"
}

_fwdports_manifest_forward_summary() {
  local generation=$1 expected_digest=$2 snapshot=$3 manifest actual_digest
  local kind leg field value _ driver direction index count=0
  local -a leg_names=() leg_drivers=()

  manifest=$generation/manifest
  # Snapshot before rendering, then authenticate the exact copied bytes. The
  # lifecycle lock excludes cooperating fwdports commands but not arbitrary
  # same-UID mutation, so merely checking the source before and after parsing
  # would leave an avoidable read race. The private snapshot also means the
  # user never sees partial output if authentication fails.
  fwdports_snapshot_trusted_file "$manifest" "$snapshot" "$generation" \
    file "$generation" || return 74
  actual_digest=$(_fwdports_runtime_sha256_file "$snapshot") || return 74
  if [[ $actual_digest != "$expected_digest" ]]; then
    printf 'fwdports: generation manifest changed before summary\n' >&2
    return 74
  fi

  # Render immutable desired state rather than the source config so the
  # summary describes the forwards the running panes actually received. Keep
  # endpoint values in their normalized raw form: local and remote forwarding
  # have different SSH bind semantics, and an invented arrow notation would
  # be easier to misread than the source data.
  printf 'fwdports: forwards\n'
  while IFS=$'\t' read -r kind leg field value _ || [[ -n ${kind:-} ]]; do
    case "$kind" in
      leg)
        leg_names+=("$leg")
        leg_drivers+=("$field")
        ;;
      set)
        case "$field" in
          local-forward | remote-forward) ;;
          *) continue ;;
        esac
        driver=
        for ((index = 0; index < ${#leg_names[@]}; index++)); do
          if [[ ${leg_names[index]} == "$leg" ]]; then
            driver=${leg_drivers[index]}
            break
          fi
        done
        [[ -n $driver ]] || {
          printf 'fwdports: forward refers to an unknown leg\n' >&2
          return 74
        }
        direction=${field%-forward}
        printf '  %s [%s] %s %s\n' "$leg" "$driver" "$direction" "$value"
        count=$((count + 1))
        ;;
    esac
  done <"$snapshot"
  if [[ $count -eq 0 ]]; then
    # An executable driver may use its own manifest keys, so make the scope of
    # this statement explicit instead of claiming the driver has no forwards.
    printf '  no standard forwards declared\n'
  fi
}

_fwdports_all_legs_preserve_degraded() {
  local resolved=$1 kind leg _ policy scan_kind scan_leg scan_policy
  local found=0

  while IFS=$'\t' read -r kind leg _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    found=1
    policy=restart
    while IFS=$'\t' read -r scan_kind scan_leg scan_policy _ ||
      [[ -n ${scan_kind:-} ]]; do
      if [[ $scan_kind == failure && $scan_leg == "$leg" ]]; then
        policy=$scan_policy
      fi
    done <"$resolved"
    [[ $policy == preserve ]] || return 1
  done <"$resolved"
  [[ $found -eq 1 ]]
}

_fwdports_generation_rollback_locked() {
  local tmux_path=$1 socket=$2 root=$3 generation=$4 digest=$5

  # Stop intent is published before cleanup, even during failed preparation.
  # That prevents a controller which happened to start early from gaining
  # permission to repair a generation being rolled back.
  fwdports_control_write "$generation" "$digest" stopping stopped \
    none none unknown || return 1
  _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
    pending "$generation" "$digest" "$FWDPORTS_SESSION_NAME" 40 0.05
}

_fwdports_start_generation() {
  local tmux_path=$1 socket=$2 root=$3 config_root=$4 allowed_root=$5
  local generation=$6 digest=$7 resolved=$8
  local target_override=${9:-}
  local kind leg driver _ runtime driver_snapshot record session='' pane
  local index prior launch_failed=0
  local -a legs=() drivers=() snapshots=() runtimes=() prepared=()

  while IFS=$'\t' read -r kind leg driver _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    legs+=("$leg")
    drivers+=("$driver")
  done <"$resolved"
  [[ -n ${legs[0]+set} ]] || {
    printf 'fwdports: selected profile has no legs\n' >&2
    return 1
  }
  fwdports_builtin_validate_profile_ports "$generation/manifest" || return 1
  # Validate every leg before invoking any interactive prepare operation.  A
  # bad later leg therefore cannot solicit credentials or leave partial state
  # for an earlier one.
  for ((index = 0; index < ${#legs[@]}; index++)); do
    leg=${legs[index]}
    driver=${drivers[index]}
    runtime=$generation/legs/$leg
    mkdir -p "$runtime" || return 1
    chmod 0700 "$runtime" || return 1
    runtimes+=("$runtime")
    if fwdports_driver_is_builtin "$driver"; then
      fwdports_builtin_prepare "$generation/manifest" "$leg" "$driver" \
        "$runtime" "$target_override" || return 1
      snapshots+=("")
    else
      driver_snapshot=
      # The snapshot is keyed by driver executable, not by leg. Reusing one
      # immutable copy lets a generic driver serve several independent legs
      # without introducing a second mutable code path into the generation.
      # Validation and preparation still run once per leg below.
      for ((prior = 0; prior < index; prior++)); do
        if [[ ${drivers[prior]} == "$driver" ]]; then
          driver_snapshot=${snapshots[prior]}
          break
        fi
      done
      if [[ -z $driver_snapshot ]]; then
        driver_snapshot=$(fwdports_driver_snapshot "$config_root" \
          "$driver" "$generation" "$allowed_root") || return 1
      fi
      snapshots+=("$driver_snapshot")
      fwdports_driver_operation "$driver_snapshot" validate \
        "$generation/manifest" "$leg" "$runtime" || return 1
    fi
  done
  for ((index = 0; index < ${#legs[@]}; index++)); do
    driver=${drivers[index]}
    if fwdports_driver_is_builtin "$driver"; then
      # Built-in adapters may opt into a foreground-only preparation phase.
      # It runs after every leg has validated, but before tmux exists, so an
      # authentication prompt stays on the invoking terminal and a failure
      # cannot leave an earlier transport running unattended.
      fwdports_builtin_interactive_prepare "$generation/manifest" \
        "${legs[index]}" "$driver" "${runtimes[index]}" || return 1
    else
      fwdports_driver_operation "${snapshots[index]}" prepare \
        "$generation/manifest" "${legs[index]}" "${runtimes[index]}" ||
        return 1
      prepared+=("${snapshots[index]}")
    fi
  done

  for ((index = 0; index < ${#legs[@]}; index++)); do
    leg=${legs[index]}
    driver=${drivers[index]}
    runtime=${runtimes[index]}
    if [[ -z $session ]]; then
      if fwdports_driver_is_builtin "$driver"; then
        record=$(fwdports_tmux_create_session "$tmux_path" "$socket" \
          "$FWDPORTS_SESSION_NAME" "${generation##*/}" "$runtime" \
          "$FWDPORTS_MODULE_DIR/builtin-runner.sh" "$runtime") ||
          launch_failed=1
      else
        record=$(fwdports_tmux_create_session "$tmux_path" "$socket" \
          "$FWDPORTS_SESSION_NAME" "${generation##*/}" "$runtime" \
          "$FWDPORTS_MODULE_DIR/driver-api.sh" run \
          "${snapshots[index]}" "$generation/manifest" "$leg" \
          "$runtime") || launch_failed=1
      fi
      [[ $launch_failed -eq 0 ]] || return 1
      IFS=$'\t' read -r session pane <<<"$record"
    else
      if fwdports_driver_is_builtin "$driver"; then
        pane=$(fwdports_tmux_split_pane "$tmux_path" "$socket" "$session" \
          "${generation##*/}" "$runtime" \
          "$FWDPORTS_MODULE_DIR/builtin-runner.sh" "$runtime") ||
          launch_failed=1
      else
        pane=$(fwdports_tmux_split_pane "$tmux_path" "$socket" "$session" \
          "${generation##*/}" "$runtime" \
          "$FWDPORTS_MODULE_DIR/driver-api.sh" run \
          "${snapshots[index]}" "$generation/manifest" "$leg" \
          "$runtime") || launch_failed=1
      fi
      if [[ $launch_failed -ne 0 ]]; then
        fwdports_tmux_abort_created_session "$tmux_path" "$socket" "$session" \
          "${generation##*/}" >/dev/null 2>&1 || true
        return 1
      fi
    fi
    if ! fwdports_tmux_configure_transport_pane "$tmux_path" "$socket" \
      "$session" "${generation##*/}" "$pane" "$leg" "$driver"; then
      fwdports_tmux_abort_created_session "$tmux_path" "$socket" "$session" \
        "${generation##*/}" >/dev/null 2>&1 || true
      return 1
    fi
    if ! fwdports_tmux_record_pane "$tmux_path" "$socket" "$session" \
      "$pane" "$generation" "$digest" "$runtime/pane"; then
      fwdports_tmux_abort_created_session "$tmux_path" "$socket" "$session" \
        "${generation##*/}" >/dev/null 2>&1 || true
      return 1
    fi
  done
  # An all-built-in profile legitimately prepares no external driver. Avoid
  # expanding that empty array under nounset on Bash 3.2.
  [[ -z ${prepared[0]+set} ]] || : "${prepared[*]}"
}

_fwdports_start_controller() {
  local tmux_path=$1 socket=$2 root=$3 generation=$4 digest=$5 session=$6
  local pane evidence=$generation/controller.pane index=0 record
  local controller_pid controller_start ready_pid ready_start

  pane=$(fwdports_tmux_create_control_window "$tmux_path" "$socket" "$session" \
    "${generation##*/}" "$generation" \
    "$FWDPORTS_MODULE_DIR/controller.sh" run "$root" "$generation" \
    "$digest") || return 1
  if ! fwdports_tmux_record_pane "$tmux_path" "$socket" "$session" \
    "$pane" "$generation" "$digest" "$evidence"; then
    # The controller pane exists but is not yet authenticated into durable
    # generation evidence. Abort only the exact session ID and nonce returned
    # by this start; the transport wrappers convert tmux HUP to TERM and reap
    # their children, so rollback cannot strand an unowned forwarding process.
    fwdports_tmux_abort_created_session "$tmux_path" "$socket" "$session" \
      "${generation##*/}" >/dev/null 2>&1 || true
    return 1
  fi
  while [[ ! -f $generation/controller.ready && $index -lt 500 ]]; do
    fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
      "$digest" "$evidence" >/dev/null 2>&1 || return 1
    sleep 0.01
    index=$((index + 1))
  done
  [[ -f $generation/controller.ready &&
    ! -L $generation/controller.ready ]] || {
    printf 'fwdports: controller did not become ready\n' >&2
    return 1
  }
  record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
    "$evidence") || return 1
  IFS=$'\t' read -r _ _ controller_pid controller_start _ <<<"$record"
  ready_pid=$(LC_ALL=C sed -n 's/^controller-pid\t//p' \
    "$generation/controller.ready") || return 1
  ready_start=$(LC_ALL=C sed -n 's/^controller-start\t//p' \
    "$generation/controller.ready") || return 1
  [[ $ready_pid == "$controller_pid" &&
    $ready_start == "$controller_start" ]] || {
    printf 'fwdports: controller readiness identity does not match pane\n' >&2
    return 1
  }
  printf '%s\t%s\n' "$controller_pid" "$controller_start"
}

fwdports_start() {
  local config=$1 profile=$2 force=$3 target_override=$4
  local config_root allowed_root workspace resolved root tmux_path socket
  local candidate='' active generation digest result status release_status
  local controller_record controller_pid=none controller_start=none
  local session_record session_id='' observed_state return_existing=0
  local forward_summary='' repair_state='' stop_existing=0
  local builtin_preflighted=0

  config_root=$(_fwdports_config_root) || {
    printf 'fwdports: HOME or XDG_CONFIG_HOME must be absolute\n' >&2
    return 1
  }
  allowed_root=${HOME:-}
  [[ $allowed_root == /* && -d $allowed_root ]] || {
    printf 'fwdports: HOME must name an existing absolute directory\n' >&2
    return 1
  }
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/fwdports-desired.XXXXXXXX") ||
    return 1
  chmod 0700 "$workspace" || {
    rm -rf -- "$workspace"
    return 1
  }
  resolved=$(_fwdports_desired_prepare "$config" "$profile" "$workspace" \
    "$allowed_root") || {
    status=$?
    rm -rf -- "$workspace"
    return "$status"
  }
  root=$(fwdports_runtime_init) || {
    status=$?
    rm -rf -- "$workspace"
    return "$status"
  }
  tmux_path=$(_fwdports_command_path tmux) || {
    rm -rf -- "$workspace"
    printf 'fwdports: tmux is required\n' >&2
    return 69
  }
  socket=$(_fwdports_tmux_socket "$root") || {
    rm -rf -- "$workspace"
    return 1
  }
  candidate=$(fwdports_lock_acquire "$root") || {
    status=$?
    rm -rf -- "$workspace"
    return "$status"
  }

  status=0
  # Recovery is also meaningful when only active exists: an authenticated
  # stopping/stopped control record commits cleanup authority before any
  # replacement dependency is considered. A running active generation is
  # observed without mutation.
  if [[ -e $root/pending || -L $root/pending ||
    -e $root/active || -L $root/active ]]; then
    _fwdports_recover_state_locked "$tmux_path" "$socket" "$root" \
      "$FWDPORTS_SESSION_NAME" 40 0.05 >/dev/null || status=$?
  fi
  if [[ $status -eq 0 && (-e $root/active || -L $root/active) ]]; then
    active=$(fwdports_pointer_read "$root" active) || status=$?
    if [[ $status -eq 0 ]]; then
      IFS=$'\t' read -r generation digest <<<"$active"
      if _fwdports_manifest_matches_desired "$generation" "$resolved" \
        "$config_root" "$allowed_root" "$target_override"; then
        observed_state=$(fwdports_status "$root" "$tmux_path" "$socket" \
          "$FWDPORTS_SESSION_NAME") || status=$?
        if [[ $status -eq 0 ]]; then
          case "$observed_state" in
            healthy | live/unverified)
              printf 'fwdports: profile %s is already running (%s)\n' \
                "$profile" "$observed_state"
              return_existing=1
              ;;
            degraded)
              if _fwdports_all_legs_preserve_degraded "$resolved"; then
                printf 'fwdports: profile %s is degraded and preserved\n' \
                  "$profile"
                return_existing=1
              else
                repair_state=$observed_state
                stop_existing=1
              fi
              ;;
            down | controller-down | stopping)
              repair_state=$observed_state
              stop_existing=1
              ;;
            *) status=74 ;;
          esac
        fi
      elif [[ $force -eq 0 ]]; then
        printf 'fwdports: a different profile or driver is already running; use --force\n' \
          >&2
        status=1
      else
        stop_existing=1
      fi
      if [[ $status -eq 0 && $stop_existing -eq 1 ]]; then
        fwdports_builtin_preflight_dependencies "$resolved" \
          "$workspace/builtin-preflight" "$target_override" || status=$?
        if [[ $status -eq 0 ]]; then
          builtin_preflighted=1
          case "$repair_state" in
            degraded)
              printf 'fwdports: repairing degraded profile %s\n' "$profile"
              ;;
            down | controller-down | stopping)
              printf 'fwdports: repairing profile %s from %s\n' \
                "$profile" "$repair_state"
              ;;
          esac
          _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
            active "$generation" "$digest" "$FWDPORTS_SESSION_NAME" \
            40 0.05 || status=$?
        fi
      fi
    fi
    if [[ $status -eq 0 && $return_existing -eq 1 ]]; then
      # Matching desired state is intentionally a no-churn success, including
      # when --force was supplied.  Full teardown remains explicit stop/start.
      forward_summary=$(_fwdports_manifest_forward_summary \
        "$generation" "$digest" "$workspace/forward-summary.manifest") ||
        status=$?
      fwdports_lock_release "$root" "$candidate"
      release_status=$?
      rm -rf -- "$workspace"
      [[ $status -eq 0 ]] || return "$status"
      [[ $release_status -eq 0 ]] || return "$release_status"
      printf '%s\n' "$forward_summary"
      return 0
    fi
  fi

  if [[ $status -eq 0 ]] && fwdports_tmux_session_named_exists \
    "$tmux_path" "$socket" "$FWDPORTS_SESSION_NAME"; then
    printf 'fwdports: an unowned tmux session named %s already exists\n' \
      "$FWDPORTS_SESSION_NAME" >&2
    status=1
  fi
  if [[ $status -eq 0 && $builtin_preflighted -eq 0 ]]; then
    fwdports_builtin_preflight_dependencies "$resolved" \
      "$workspace/builtin-preflight" "$target_override" || status=$?
    [[ $status -ne 0 ]] || builtin_preflighted=1
  fi
  if [[ $status -eq 0 ]]; then
    generation=$(fwdports_generation_create "$root" "$resolved" \
      "$target_override") || status=$?
  fi
  if [[ $status -eq 0 ]]; then
    digest=$(fwdports_generation_manifest_digest "$generation") || status=$?
  fi
  if [[ $status -eq 0 ]]; then
    fwdports_control_write "$generation" "$digest" preparing running \
      none none unknown || status=$?
  fi
  if [[ $status -eq 0 ]]; then
    fwdports_pointer_publish "$root" pending "$generation" "$digest" ||
      status=$?
  fi
  if [[ $status -eq 0 ]]; then
    _fwdports_start_generation "$tmux_path" "$socket" "$root" \
      "$config_root" "$allowed_root" "$generation" "$digest" "$resolved" \
      "$target_override" ||
      status=$?
  fi
  if [[ $status -eq 0 ]]; then
    for session_record in "$generation"/legs/*/pane; do
      [[ -f $session_record && ! -L $session_record ]] || continue
      result=$(_fwdports_pane_evidence_read "$generation" "$digest" \
        "$session_record") || {
        status=$?
        break
      }
      session_id=${result%%$'\t'*}
      break
    done
    [[ -n $session_id ]] || status=1
  fi
  if [[ $status -eq 0 ]]; then
    controller_record=$(_fwdports_start_controller "$tmux_path" "$socket" \
      "$root" "$generation" "$digest" "$session_id") || status=$?
  fi
  if [[ $status -eq 0 ]]; then
    IFS=$'\t' read -r controller_pid controller_start \
      <<<"$controller_record"
    fwdports_control_write "$generation" "$digest" running running \
      "$controller_pid" "$controller_start" unknown || status=$?
  fi
  if [[ $status -eq 0 ]]; then
    forward_summary=$(_fwdports_manifest_forward_summary \
      "$generation" "$digest" "$workspace/forward-summary.manifest") ||
      status=$?
  fi
  if [[ $status -eq 0 ]]; then
    fwdports_pointer_publish "$root" active "$generation" "$digest" ||
      status=$?
  fi
  if [[ $status -eq 0 ]]; then
    fwdports_pointer_remove "$root" pending "$generation" "$digest" ||
      status=$?
  fi

  if [[ $status -ne 0 && -n ${generation:-} && -n ${digest:-} &&
    (-e $root/pending || -L $root/pending) ]]; then
    _fwdports_generation_rollback_locked "$tmux_path" "$socket" "$root" \
      "$generation" "$digest" >/dev/null 2>&1 || true
  fi
  fwdports_lock_release "$root" "$candidate"
  release_status=$?
  rm -rf -- "$workspace"
  [[ $status -ne 0 ]] && return "$status"
  [[ $release_status -eq 0 ]] || return "$release_status"
  printf 'fwdports: started profile %s\n' "$profile"
  printf '%s\n' "$forward_summary"
}

fwdports_stop() {
  local root tmux_path socket candidate pointer generation digest status=0
  local release_status
  root=$(_fwdports_state_root_path) || return 1
  [[ -d $root && ! -L $root ]] || {
    printf 'stopped\n'
    return 0
  }
  tmux_path=$(_fwdports_command_path tmux) || return 69
  socket=$(_fwdports_tmux_socket "$root") || return 1
  candidate=$(fwdports_lock_acquire "$root") || return $?
  if [[ -e $root/pending || -L $root/pending ]]; then
    _fwdports_recover_state_locked "$tmux_path" "$socket" "$root" \
      "$FWDPORTS_SESSION_NAME" 40 0.05 >/dev/null || status=$?
  fi
  if [[ $status -eq 0 && (-e $root/active || -L $root/active) ]]; then
    pointer=$(fwdports_pointer_read "$root" active) || status=$?
    if [[ $status -eq 0 ]]; then
      IFS=$'\t' read -r generation digest <<<"$pointer"
      _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
        active "$generation" "$digest" "$FWDPORTS_SESSION_NAME" \
        40 0.05 || status=$?
    fi
  fi
  fwdports_lock_release "$root" "$candidate"
  release_status=$?
  [[ $status -ne 0 ]] && return "$status"
  [[ $release_status -eq 0 ]] || return "$release_status"
  printf 'stopped\n'
}

fwdports_status_command() {
  local root tmux_path socket
  root=$(_fwdports_state_root_path) || return 1
  tmux_path=$(_fwdports_command_path tmux) || return 69
  if [[ ! -d $root || -L $root ]]; then
    printf 'stopped\n'
    return 0
  fi
  socket=$(_fwdports_tmux_socket "$root") || return 1
  fwdports_status "$root" "$tmux_path" "$socket" "$FWDPORTS_SESSION_NAME"
}

_fwdports_inspect_pane_observation() {
  local tmux_path=$1 socket=$2 generation=$3 digest=$4 evidence=$5
  local record session pane pid _ verify_status state location
  local window_id window_name pane_dead

  record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
    "$evidence") || return 74
  IFS=$'\t' read -r session pane pid _ <<<"$record"
  if fwdports_tmux_verify_pane "$tmux_path" "$socket" "$generation" \
    "$digest" "$evidence"; then
    state=live
  else
    verify_status=$?
    case "$verify_status" in
      1) state=down ;;
      *)
        printf 'fwdports: pane ownership cannot be inspected safely\n' >&2
        return 74
        ;;
    esac
  fi
  if location=$(fwdports_tmux_pane_location "$tmux_path" "$socket" \
    "$session" "$pane" 2>/dev/null); then
    IFS=$'\t' read -r window_id window_name pane_dead <<<"$location"
    if [[ ($state == live && $pane_dead != 0) ||
      ($state == down && $pane_dead != 1) ]]; then
      printf 'fwdports: tmux pane state changed during inspection\n' >&2
      return 74
    fi
  elif [[ $state == live ]]; then
    printf 'fwdports: live tmux pane location is unavailable\n' >&2
    return 74
  else
    window_id=unavailable
    window_name=unavailable
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$state" "$session" "$window_id" "$window_name" "$pane" "$pid"
}

_fwdports_inspect_transport_state() {
  local generation=$1 leg=$2 driver=$3 pane=$4 pane_state=$5
  local runtime snapshot driver_status

  if [[ $pane_state != live ]]; then
    printf 'down (foreground pane)\n'
    return 0
  fi
  if fwdports_driver_is_builtin "$driver"; then
    printf 'not separately observed (supervisor live)\n'
    return 0
  fi
  runtime=$generation/legs/$leg
  snapshot=$generation/drivers/$driver
  if fwdports_driver_operation "$snapshot" is-live \
    "$generation/manifest" "$leg" "$runtime" "$pane" >/dev/null; then
    driver_status=0
  else
    driver_status=$?
  fi
  case "$driver_status" in
    0) printf 'live (driver-reported)\n' ;;
    1) printf 'down (driver-reported)\n' ;;
    2) printf 'not separately reported (pane live)\n' ;;
    *)
      printf 'fwdports: driver liveness check failed for %s\n' "$leg" >&2
      return 74
      ;;
  esac
}

_fwdports_inspect_render_check() {
  local probe_type=$1 host=$2 port=$3 label=$4 check_result check_status

  [[ ($probe_type == loopback || $probe_type == tcp) && -n $host &&
    $port =~ ^[0-9]+$ && -n $label ]] || return 74
  if check_result=$(fwdports_health_probe_local_tcp "$host" "$port"); then
    check_status=0
  else
    check_status=$?
  fi
  case "$check_status" in
    0 | 1 | 2) ;;
    *) return 74 ;;
  esac
  printf '      check: %s; point-in-time local TCP connect to %s port %s (%s; label %s)\n' \
    "$check_result" "$host" "$port" "$probe_type" "$label"
}

_fwdports_inspect_render_leg() {
  local tmux_path=$1 socket=$2 generation=$3 digest=$4 manifest=$5
  local leg=$6 driver=$7 evidence observation pane_state session
  local window_id window_name pane pid transport
  local kind record_leg field value extra probe_type host port label
  local forward_count=0 check_count=0

  evidence=$generation/legs/$leg/pane
  observation=$(_fwdports_inspect_pane_observation "$tmux_path" "$socket" \
    "$generation" "$digest" "$evidence") || return $?
  IFS=$'\t' read -r pane_state session window_id window_name pane pid \
    <<<"$observation"
  transport=$(_fwdports_inspect_transport_state "$generation" "$leg" \
    "$driver" "$pane" "$pane_state") || return $?

  printf '    %s [%s]\n' "$leg" "$driver"
  if [[ $window_id == unavailable ]]; then
    printf '      tmux: %s; session %s; window unavailable; pane %s; pid %s\n' \
      "$pane_state" "$session" "$pane" "$pid"
  else
    printf '      tmux: %s; session %s; window %s (%s); pane %s; pid %s\n' \
      "$pane_state" "$session" "$window_id" "$window_name" "$pane" "$pid"
  fi
  printf '      transport: %s\n' "$transport"

  while IFS=$'\t' read -r kind record_leg field value extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == set && $record_leg == "$leg" ]] || continue
    case "$field" in
      local-forward | remote-forward)
        printf '      standard forward: %s %s\n' "${field%-forward}" "$value"
        forward_count=$((forward_count + 1))
        ;;
    esac
  done <"$manifest"
  if [[ $forward_count -eq 0 ]]; then
    printf '      standard forward: none declared\n'
  fi

  while IFS=$'\t' read -r kind record_leg probe_type host port label extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == check && $record_leg == "$leg" ]] || continue
    [[ -z $extra && ($probe_type == loopback || $probe_type == tcp) ]] ||
      return 74
    _fwdports_inspect_render_check "$probe_type" "$host" "$port" \
      "$label" || return $?
    check_count=$((check_count + 1))
  done <"$manifest"
  if [[ $check_count -eq 0 ]]; then
    printf '      check: none configured\n'
  fi
}

_fwdports_inspect_render_active() {
  local tmux_path=$1 socket=$2 generation=$3 digest=$4 manifest=$5 overall=$6
  local kind first second extra profile='' profile_count=0 index
  local observation state session window_id window_name pane pid
  local -a legs=() drivers=()

  while IFS=$'\t' read -r kind first second extra || [[ -n ${kind:-} ]]; do
    [[ $kind == profile ]] || continue
    [[ -n $first && -z $second && -z $extra ]] || return 74
    profile=$first
    profile_count=$((profile_count + 1))
  done <"$manifest"
  [[ $profile_count -eq 1 ]] || return 74
  observation=$(_fwdports_inspect_pane_observation "$tmux_path" "$socket" \
    "$generation" "$digest" "$generation/controller.pane") || return $?
  IFS=$'\t' read -r state session window_id window_name pane pid \
    <<<"$observation"

  printf 'fwdports inspect\n'
  printf '  overall: %s\n' "$overall"
  printf '  profile: %s\n' "$profile"
  printf '  generation: %s\n' "${generation##*/}"
  printf '  check semantics: local TCP connect only; not end-to-end destination proof\n'
  if [[ $window_id == unavailable ]]; then
    printf '  controller: %s; session %s; window unavailable; pane %s; pid %s\n' \
      "$state" "$session" "$pane" "$pid"
  else
    printf '  controller: %s; session %s; window %s (%s); pane %s; pid %s\n' \
      "$state" "$session" "$window_id" "$window_name" "$pane" "$pid"
  fi
  printf '  legs:\n'
  while IFS=$'\t' read -r kind first second extra || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    [[ -n $first && -n $second && -z $extra ]] || return 74
    legs+=("$first")
    drivers+=("$second")
  done <"$manifest"
  [[ -n ${legs[0]+set} ]] || return 74
  for ((index = 0; index < ${#legs[@]}; index++)); do
    _fwdports_inspect_render_leg "$tmux_path" "$socket" "$generation" \
      "$digest" "$manifest" "${legs[index]}" "${drivers[index]}" ||
      return $?
  done
}

fwdports_inspect() {
  local root tmux_path socket overall status pointer generation digest
  local workspace manifest report actual_digest current report_status

  root=$(_fwdports_state_root_path) || return 1
  if [[ ! -d $root || -L $root ]]; then
    printf 'fwdports inspect\n'
    printf '  overall: stopped\n'
    printf '  active generation: none\n'
    return 0
  fi
  tmux_path=$(_fwdports_command_path tmux) || return 69
  socket=$(_fwdports_tmux_socket "$root") || return 1
  if [[ ! -e $root/active && ! -L $root/active ]]; then
    if overall=$(fwdports_status "$root" "$tmux_path" "$socket" \
      "$FWDPORTS_SESSION_NAME"); then
      status=0
    else
      status=$?
    fi
    [[ $status -eq 0 || $status -eq 1 ]] || return "$status"
    printf 'fwdports inspect\n'
    printf '  overall: %s\n' "$overall"
    printf '  active generation: none\n'
    return "$status"
  fi

  pointer=$(fwdports_pointer_read "$root" active) || return 74
  IFS=$'\t' read -r generation digest <<<"$pointer"
  overall=$(fwdports_status "$root" "$tmux_path" "$socket" \
    "$FWDPORTS_SESSION_NAME") || return $?
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/fwdports-inspect.XXXXXXXX") ||
    return 1
  chmod 0700 "$workspace" || {
    rm -rf -- "$workspace"
    return 1
  }
  manifest=$workspace/manifest
  report=$workspace/report
  if ! fwdports_snapshot_trusted_file "$generation/manifest" "$manifest" \
    "$generation" file "$generation"; then
    rm -rf -- "$workspace"
    return 74
  fi
  actual_digest=$(_fwdports_runtime_sha256_file "$manifest") || {
    rm -rf -- "$workspace"
    return 74
  }
  if [[ $actual_digest != "$digest" ]]; then
    rm -rf -- "$workspace"
    printf 'fwdports: generation manifest changed before inspection\n' >&2
    return 74
  fi
  if _fwdports_inspect_render_active "$tmux_path" "$socket" "$generation" \
    "$digest" "$manifest" "$overall" >"$report"; then
    report_status=0
  else
    report_status=$?
  fi
  if [[ $report_status -eq 0 ]]; then
    current=$(fwdports_pointer_read "$root" active) || report_status=74
    [[ $report_status -ne 0 || $current == "$pointer" ]] || {
      printf 'fwdports: active generation changed during inspection\n' >&2
      report_status=74
    }
  fi
  if [[ $report_status -eq 0 ]]; then
    cat "$report" || report_status=$?
  fi
  rm -rf -- "$workspace"
  return "$report_status"
}

_fwdports_attach_pane_record() {
  local generation=$1 expected_digest=$2 snapshot=$3 manifest actual_digest
  local kind leg _ evidence

  manifest=$generation/manifest
  fwdports_snapshot_trusted_file "$manifest" "$snapshot" "$generation" \
    file "$generation" || return 74
  actual_digest=$(_fwdports_runtime_sha256_file "$snapshot") || return 74
  if [[ $actual_digest != "$expected_digest" ]]; then
    printf 'fwdports: generation manifest changed before attach\n' >&2
    return 74
  fi

  # The manifest is the user-visible declaration order. Filesystem glob order
  # is unrelated and could focus a later pane merely because its leg name sorts
  # first. Skip a leg whose pane was never published, but fail closed on
  # malformed evidence for any published pane.
  while IFS=$'\t' read -r kind leg _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    [[ $leg =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 74
    evidence=$generation/legs/$leg/pane
    [[ -f $evidence && ! -L $evidence ]] || continue
    _fwdports_pane_evidence_read "$generation" "$expected_digest" \
      "$evidence"
    return $?
  done <"$snapshot"
  return 1
}

fwdports_attach() {
  local root tmux_path socket pointer generation digest record record_status
  local workspace session pane
  root=$(_fwdports_state_root_path) || return 1
  [[ -d $root && ! -L $root ]] || {
    printf 'fwdports: no active session\n' >&2
    return 1
  }
  pointer=$(fwdports_pointer_read "$root" active) || return 1
  IFS=$'\t' read -r generation digest <<<"$pointer"
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/fwdports-attach.XXXXXXXX") ||
    return 1
  chmod 0700 "$workspace" || {
    rm -rf -- "$workspace"
    return 1
  }
  if record=$(_fwdports_attach_pane_record "$generation" "$digest" \
    "$workspace/manifest"); then
    record_status=0
  else
    record_status=$?
  fi
  rm -rf -- "$workspace"
  [[ $record_status -eq 0 ]] || return "$record_status"
  IFS=$'\t' read -r session pane _ <<<"$record"
  [[ -n ${session:-} ]] || return 1
  tmux_path=$(_fwdports_command_path tmux) || return 69
  socket=$(_fwdports_tmux_socket "$root") || return 1
  fwdports_tmux_focus_pane "$tmux_path" "$socket" "$session" \
    "${generation##*/}" "$pane" || return 1
  TMUX='' TMUX_PANE='' exec "$tmux_path" -S "$socket" \
    attach-session -t "$session"
}
