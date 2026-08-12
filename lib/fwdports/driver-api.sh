#!/usr/bin/env bash
# Executable driver boundary.
#
# Drivers are trusted programs, but they are still deliberately invoked as
# separate processes through a fixed argv protocol.  That keeps a consumer
# from changing core traps, shell options, variables, or working directory by
# being sourced into the supervisor.  Each generation snapshots one exact
# executable so a later dotfiles update cannot change a running generation's
# behavior halfway through its lifetime.

fwdports_driver_is_builtin() {
  # Keep the reserved-name and lifecycle decisions on one list. A built-in
  # omitted from discovery, cleanup, liveness, or launch would be mistaken for
  # an external executable and cross the wrong trust boundary.
  case "$1" in
    ssh | autossh | et) return 0 ;;
    *) return 1 ;;
  esac
}

_fwdports_driver_identifier() {
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]
}

fwdports_driver_discover() {
  local config_root=$1 name=$2 allowed_target_root=${3:-$1}
  local drivers_dir source

  _fwdports_driver_identifier "$name" || {
    printf 'fwdports: invalid driver name: %s\n' "$name" >&2
    return 1
  }
  if fwdports_driver_is_builtin "$name"; then
    # Built-ins carry additional executable/config drift protections.  A
    # same-named drop-in must never silently replace that security model.
    printf 'fwdports: built-in driver name is reserved: %s\n' "$name" >&2
    return 1
  fi
  [[ $config_root == /* && -d "$config_root" && ! -L "$config_root" ]] || {
    printf 'fwdports: driver configuration root is unavailable\n' >&2
    return 1
  }
  drivers_dir=$config_root/drivers.d
  [[ -d "$drivers_dir" && ! -L "$drivers_dir" ]] || {
    printf 'fwdports: driver directory is unavailable: %s\n' \
      "$drivers_dir" >&2
    return 1
  }
  # The anchor itself has no parent *inside* the anchor, so validate that node
  # directly.  Descendants still use the full parent-chain validator below.
  _fwdports_runtime_validate_node "$config_root" \
    'driver configuration root' || return 1
  fwdports_validate_trusted_path "$drivers_dir" directory "$config_root" \
    "$config_root" >/dev/null || return 1
  source=$drivers_dir/$name
  # Validate both the configured link and its canonical executable now, but
  # preserve the configured path for the caller. Snapshotting deliberately
  # repeats that validation before and after copying; returning only the
  # canonical target here would lose the config-root anchor and incorrectly
  # reject a trusted dotfiles-managed link outside the visible drivers.d.
  fwdports_validate_trusted_path "$source" executable "$config_root" \
    "$allowed_target_root" >/dev/null || return 1
  printf '%s\n' "$source"
}

fwdports_driver_snapshot() {
  local config_root=$1 name=$2 generation=$3 source drivers destination
  local allowed_target_root=${4:-$1}
  local api_version digest digest_tmp old_umask

  source=$(fwdports_driver_discover "$config_root" "$name" \
    "$allowed_target_root") || return 1
  [[ -d "$generation" && ! -L "$generation" &&
    -f "$generation/manifest" && ! -L "$generation/manifest" ]] || {
    printf 'fwdports: driver generation is unavailable\n' >&2
    return 1
  }
  drivers=$generation/drivers
  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$drivers" || ! chmod 0700 "$drivers"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  destination=$drivers/$name
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    printf 'fwdports: generation driver already exists: %s\n' "$name" >&2
    return 1
  }

  fwdports_snapshot_trusted_file "$source" "$destination" "$config_root" \
    executable "$allowed_target_root" || return 1
  api_version=$("$destination" api-version 2>/dev/null) || {
    rm -f -- "$destination"
    printf 'fwdports: driver API query failed: %s\n' "$name" >&2
    return 1
  }
  if [[ $api_version != 1 ]]; then
    rm -f -- "$destination"
    printf 'fwdports: driver %s requires unsupported API %s\n' \
      "$name" "${api_version:-<empty>}" >&2
    return 1
  fi

  digest=$(_fwdports_runtime_sha256_file "$destination") || {
    rm -f -- "$destination"
    return 1
  }
  old_umask=$(umask)
  umask 077
  digest_tmp=$(mktemp "$drivers/.${name}.digest.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$destination"
    return 1
  }
  umask "$old_umask"
  if ! printf '%s\n' "$digest" >"$digest_tmp" ||
    ! chmod 0600 "$digest_tmp" ||
    ! mv -f -- "$digest_tmp" "$destination.digest"; then
    rm -f -- "$digest_tmp" "$destination" "$destination.digest"
    return 1
  fi
  printf '%s\n' "$destination"
}

fwdports_driver_operation() {
  local driver=$1 operation=$2 manifest=$3 leg=$4 runtime=$5
  shift 5

  [[ -f "$driver" && -x "$driver" && ! -L "$driver" ]] || {
    printf 'fwdports: generation driver is unavailable\n' >&2
    return 1
  }
  [[ -f "$manifest" && ! -L "$manifest" &&
    -d "$runtime" && ! -L "$runtime" ]] || {
    printf 'fwdports: driver operation paths are unavailable\n' >&2
    return 1
  }
  _fwdports_driver_identifier "$leg" || {
    printf 'fwdports: invalid driver leg name\n' >&2
    return 1
  }
  case "$operation" in
    validate | prepare)
      [[ $# -eq 0 ]] || return 64
      "$driver" "$operation" "$manifest" "$leg" "$runtime"
      ;;
    is-live)
      [[ $# -eq 1 ]] || return 64
      "$driver" "$operation" "$manifest" "$leg" "$runtime" "$1"
      ;;
    cleanup)
      [[ $# -le 1 ]] || return 64
      "$driver" "$operation" "$manifest" "$leg" "$runtime" \
        "${1-}"
      ;;
    run)
      [[ $# -eq 0 ]] || return 64
      # The pane owns this foreground process.  `exec` is essential: leaving
      # an extra shell between tmux and the driver would make recorded process
      # identity describe the wrapper rather than the lifetime process.
      exec "$driver" run "$manifest" "$leg" "$runtime"
      ;;
    *)
      printf 'fwdports: unknown driver operation: %s\n' "$operation" >&2
      return 64
      ;;
  esac
}

_fwdports_driver_api_main() {
  local operation=${1:-} module_dir
  shift || true
  module_dir=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    return 1
  # Runtime supplies the path and digest adapters used to authenticate a
  # generation-owned snapshot.  The inventory checks both files separately.
  # shellcheck disable=SC1091
  source "$module_dir/runtime.sh"
  case "$operation" in
    run)
      [[ $# -eq 4 ]] || return 64
      fwdports_driver_operation "$1" run "$2" "$3" "$4"
      ;;
    *)
      printf 'fwdports: unsupported internal driver operation\n' >&2
      return 64
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -u
  _fwdports_driver_api_main "$@"
  exit $?
fi
