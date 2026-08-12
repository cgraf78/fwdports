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
    case "$driver" in
      ssh | autossh) continue ;;
    esac
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
    case "$driver" in
      ssh | autossh)
        fwdports_builtin_prepare "$generation/manifest" "$leg" "$driver" \
          "$runtime" "$target_override" || return 1
        snapshots+=("")
        ;;
      *)
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
        ;;
    esac
  done
  for ((index = 0; index < ${#legs[@]}; index++)); do
    driver=${drivers[index]}
    case "$driver" in
      ssh | autossh) ;;
      *)
        fwdports_driver_operation "${snapshots[index]}" prepare \
          "$generation/manifest" "${legs[index]}" "${runtimes[index]}" ||
          return 1
        prepared+=("${snapshots[index]}")
        ;;
    esac
  done

  for ((index = 0; index < ${#legs[@]}; index++)); do
    leg=${legs[index]}
    driver=${drivers[index]}
    runtime=${runtimes[index]}
    if [[ -z $session ]]; then
      case "$driver" in
        ssh | autossh)
          record=$(fwdports_tmux_create_session "$tmux_path" "$socket" \
            "$FWDPORTS_SESSION_NAME" "${generation##*/}" "$runtime" \
            "$FWDPORTS_MODULE_DIR/builtin-runner.sh" "$runtime") ||
            launch_failed=1
          ;;
        *)
          record=$(fwdports_tmux_create_session "$tmux_path" "$socket" \
            "$FWDPORTS_SESSION_NAME" "${generation##*/}" "$runtime" \
            "$FWDPORTS_MODULE_DIR/driver-api.sh" run \
            "${snapshots[index]}" "$generation/manifest" "$leg" \
            "$runtime") || launch_failed=1
          ;;
      esac
      [[ $launch_failed -eq 0 ]] || return 1
      IFS=$'\t' read -r session pane <<<"$record"
    else
      case "$driver" in
        ssh | autossh)
          pane=$(fwdports_tmux_split_pane "$tmux_path" "$socket" "$session" \
            "${generation##*/}" "$runtime" \
            "$FWDPORTS_MODULE_DIR/builtin-runner.sh" "$runtime") ||
            launch_failed=1
          ;;
        *)
          pane=$(fwdports_tmux_split_pane "$tmux_path" "$socket" "$session" \
            "${generation##*/}" "$runtime" \
            "$FWDPORTS_MODULE_DIR/driver-api.sh" run \
            "${snapshots[index]}" "$generation/manifest" "$leg" \
            "$runtime") || launch_failed=1
          ;;
      esac
      if [[ $launch_failed -ne 0 ]]; then
        fwdports_tmux_abort_created_session "$tmux_path" "$socket" "$session" \
          "${generation##*/}" >/dev/null 2>&1 || true
        return 1
      fi
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

  pane=$(fwdports_tmux_split_pane "$tmux_path" "$socket" "$session" \
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
  local forward_summary=''

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
  if [[ -e $root/pending || -L $root/pending ]]; then
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
                printf 'fwdports: repairing degraded profile %s\n' "$profile"
                _fwdports_stop_generation_locked "$tmux_path" "$socket" \
                  "$root" active "$generation" "$digest" \
                  "$FWDPORTS_SESSION_NAME" 40 0.05 || status=$?
              fi
              ;;
            down | controller-down | stopping)
              printf 'fwdports: repairing profile %s from %s\n' \
                "$profile" "$observed_state"
              _fwdports_stop_generation_locked "$tmux_path" "$socket" \
                "$root" active "$generation" "$digest" \
                "$FWDPORTS_SESSION_NAME" 40 0.05 || status=$?
              ;;
            *) status=74 ;;
          esac
        fi
      elif [[ $force -eq 0 ]]; then
        printf 'fwdports: a different profile or driver is already running; use --force\n' \
          >&2
        status=1
      else
        _fwdports_stop_generation_locked "$tmux_path" "$socket" "$root" \
          active "$generation" "$digest" "$FWDPORTS_SESSION_NAME" \
          40 0.05 || status=$?
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

fwdports_attach() {
  local root tmux_path socket pointer generation digest evidence record session
  root=$(_fwdports_state_root_path) || return 1
  [[ -d $root && ! -L $root ]] || {
    printf 'fwdports: no active session\n' >&2
    return 1
  }
  pointer=$(fwdports_pointer_read "$root" active) || return 1
  IFS=$'\t' read -r generation digest <<<"$pointer"
  for evidence in "$generation"/legs/*/pane; do
    [[ -f $evidence && ! -L $evidence ]] || continue
    record=$(_fwdports_pane_evidence_read "$generation" "$digest" \
      "$evidence") || return 1
    session=${record%%$'\t'*}
    break
  done
  [[ -n ${session:-} ]] || return 1
  tmux_path=$(_fwdports_command_path tmux) || return 69
  socket=$(_fwdports_tmux_socket "$root") || return 1
  TMUX='' TMUX_PANE='' exec "$tmux_path" -S "$socket" -f /dev/null \
    attach-session -t "$session"
}
