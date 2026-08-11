#!/usr/bin/env bash
# Built-in transport validation and argv construction. This module does not
# launch a shell command string: every option remains a separately validated
# argv element all the way to exec.

_fwdports_stat_identity() {
  local path=$1 output

  if output=$(LC_ALL=C stat -c '%u %a %d %i %s %Y' -- "$path" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  # BSD stat treats `--` as a pathname rather than an option terminator.
  if output=$(LC_ALL=C stat -f '%u %Lp %d %i %z %m' "$path" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

_fwdports_canonical_executable() {
  local requested=$1 candidate target directory depth=0

  candidate=$(type -P -- "$requested" 2>/dev/null) || return 1
  case "$candidate" in
    /*) ;;
    *) candidate=$PWD/$candidate ;;
  esac

  # Resolve one link at a time instead of relying on GNU `readlink -f`, which
  # is absent from stock macOS. The bounded loop also rejects link cycles.
  while [[ -L "$candidate" ]]; do
    depth=$((depth + 1))
    ((depth <= 40)) || return 1
    target=$(readlink "$candidate") || return 1
    case "$target" in
      /*) candidate=$target ;;
      *) candidate=${candidate%/*}/$target ;;
    esac
  done
  directory=$(cd -P -- "${candidate%/*}" 2>/dev/null && pwd -P) || return 1
  candidate=$directory/${candidate##*/}
  [[ -f "$candidate" && -x "$candidate" && ! -L "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

_fwdports_sha256_file() {
  local path=$1 output

  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$path") || return 1
    printf '%s\n' "${output%% *}"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$path") || return 1
    printf '%s\n' "${output%% *}"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    output=$(openssl dgst -sha256 "$path") || return 1
    output=${output##*= }
    [[ $output =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    # `${value,,}` is Bash 4-only; `tr` keeps the fallback usable by the
    # stock Bash shipped with macOS.
    printf '%s\n' "$output" | LC_ALL=C tr 'A-F' 'a-f'
    return 0
  fi
  return 1
}

fwdports_ssh_effective_digest() {
  local ssh_path=$1 target=$2 argv_file=$3 output=$4
  local output_dir old_umask baseline raw normalized stderr_file digest tmp
  local line status index skip=0 keyword remainder ambient_error=''
  local -a argv=() probe_argv=()

  [[ -x "$ssh_path" && -f "$ssh_path" ]] || {
    printf 'fwdports: resolved OpenSSH executable is unavailable\n' >&2
    return 1
  }
  [[ $target != -* && $target =~ ^[][A-Za-z0-9._:@%-]+$ ]] || {
    printf 'fwdports: unsafe SSH target\n' >&2
    return 1
  }
  [[ -f "$argv_file" && ! -L "$argv_file" ]] || {
    printf 'fwdports: SSH argv file is unavailable\n' >&2
    return 1
  }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line && $line != *$'\t'* && $line != *$'\r'* ]] || {
      printf 'fwdports: SSH argv file contains an invalid element\n' >&2
      return 1
    }
    argv+=("$line")
  done <"$argv_file"
  for ((index = 0; index < ${#argv[@]}; index++)); do
    if [[ $skip -eq 1 ]]; then
      skip=0
      continue
    fi
    case ${argv[index]} in
      -L | -R | -D)
        skip=1
        ;;
      *) probe_argv+=("${argv[index]}") ;;
    esac
  done
  [[ $skip -eq 0 ]] || {
    printf 'fwdports: SSH argv ends inside a forwarding option\n' >&2
    return 1
  }

  output_dir=${output%/*}
  [[ $output_dir != "$output" ]] || output_dir=.
  old_umask=$(umask)
  umask 077
  baseline=$(mktemp "$output_dir/.fwdports.ssh-baseline.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  raw=$(mktemp "$output_dir/.fwdports.ssh-config.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$baseline"
    return 1
  }
  normalized=$(mktemp "$output_dir/.fwdports.ssh-normalized.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$baseline" "$raw"
    return 1
  }
  stderr_file=$(mktemp "$output_dir/.fwdports.ssh-stderr.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$baseline" "$raw" "$normalized"
    return 1
  }
  umask "$old_umask"

  # Expand once without the manifest-owned forwards. Any remaining forward or
  # remote command came from trusted ambient SSH configuration but is outside
  # this generation's manifest, so launching it would make cleanup/status lie
  # about the resources fwdports owns.
  if ! LC_ALL=C "$ssh_path" -G \
    "${probe_argv[@]+"${probe_argv[@]}"}" "$target" \
    >"$baseline" 2>"$stderr_file"; then
    rm -f -- "$baseline" "$raw" "$normalized" "$stderr_file"
    printf 'fwdports: OpenSSH baseline configuration failed\n' >&2
    return 1
  fi
  while read -r keyword remainder; do
    case "$keyword" in
      localforward | remoteforward | dynamicforward)
        ambient_error='ambient SSH forwarding is not allowed'
        break
        ;;
      remotecommand)
        if [[ $remainder != none ]]; then
          ambient_error='ambient SSH remote command is not allowed'
          break
        fi
        ;;
    esac
  done <"$baseline"
  if [[ -n $ambient_error ]]; then
    rm -f -- "$baseline" "$raw" "$normalized" "$stderr_file"
    printf 'fwdports: %s\n' "$ambient_error" >&2
    return 1
  fi

  # The digest covers OpenSSH's complete effective view, including trusted
  # user/system configuration. Raw expansion may contain local paths and user
  # names, so it lives only in private temporary files and is never logged.
  if LC_ALL=C "$ssh_path" -G \
    "${argv[@]+"${argv[@]}"}" "$target" >"$raw" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status -ne 0 ]]; then
    rm -f -- "$baseline" "$raw" "$normalized" "$stderr_file"
    printf 'fwdports: OpenSSH effective configuration failed\n' >&2
    return "$status"
  fi
  if ! LC_ALL=C sed -e 's/\r$//' -e 's/[[:space:]]*$//' \
    "$raw" >"$normalized"; then
    rm -f -- "$baseline" "$raw" "$normalized" "$stderr_file"
    return 1
  fi
  digest=$(_fwdports_sha256_file "$normalized") || {
    rm -f -- "$baseline" "$raw" "$normalized" "$stderr_file"
    printf 'fwdports: no usable SHA-256 implementation\n' >&2
    return 1
  }
  rm -f -- "$baseline" "$raw" "$normalized" "$stderr_file"

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! printf '%s\n' "$digest" >"$tmp" || ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fwdports_ssh_safe_target() {
  [[ $1 != -* && $1 =~ ^[][A-Za-z0-9._:@%-]+$ ]]
}

_fwdports_ssh_safe_forward() {
  # Keep v1 deliberately narrower than OpenSSH's full forwarding grammar.
  # Whitespace, option-looking values, Unix sockets, and expansion tokens are
  # rejected so a record remains one unambiguous network-forward argv value.
  [[ $1 != -* && $1 == *:* && $1 =~ ^[][A-Za-z0-9._:@%-]+$ ]]
}

fwdports_ssh_build_argv() {
  local manifest=$1 leg_name=$2 target_override=$3 argv_output=$4
  local target_output=$5 kind leg key value _extra driver='' host=''
  local identity_file='' connect_timeout='' server_alive_interval=''
  local server_alive_count_max='' tcp_keep_alive='' batch_mode=''
  local target old_umask argv_tmp target_tmp
  local -a local_forwards=() remote_forwards=() argv=()

  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    printf 'fwdports: resolved manifest is unavailable\n' >&2
    return 1
  }
  while IFS=$'\t' read -r kind leg key value _extra || [[ -n $kind ]]; do
    case "$kind" in
      leg)
        if [[ $leg == "$leg_name" ]]; then
          driver=$key
        fi
        ;;
      set)
        [[ $leg == "$leg_name" ]] || continue
        case "$key" in
          host) host=$value ;;
          local-forward)
            _fwdports_ssh_safe_forward "$value" || {
              printf 'fwdports: unsafe local-forward for leg %s\n' \
                "$leg_name" >&2
              return 1
            }
            local_forwards+=("$value")
            ;;
          remote-forward)
            _fwdports_ssh_safe_forward "$value" || {
              printf 'fwdports: unsafe remote-forward for leg %s\n' \
                "$leg_name" >&2
              return 1
            }
            remote_forwards+=("$value")
            ;;
          identity-file) identity_file=$value ;;
          connect-timeout) connect_timeout=$value ;;
          server-alive-interval) server_alive_interval=$value ;;
          server-alive-count-max) server_alive_count_max=$value ;;
          tcp-keep-alive) tcp_keep_alive=$value ;;
          batch-mode) batch_mode=$value ;;
          *)
            printf 'fwdports: unknown SSH key for leg %s: %s\n' \
              "$leg_name" "$key" >&2
            return 1
            ;;
        esac
        ;;
    esac
  done <"$manifest"

  [[ $driver == ssh || $driver == autossh ]] || {
    printf 'fwdports: leg is not an SSH driver: %s\n' "$leg_name" >&2
    return 1
  }
  if [[ -n $target_override ]]; then
    target=$target_override
  else
    target=$host
  fi
  _fwdports_ssh_safe_target "$target" || {
    printf 'fwdports: SSH host is missing or unsafe for leg %s\n' \
      "$leg_name" >&2
    return 1
  }
  if ((${#local_forwards[@]} == 0 && ${#remote_forwards[@]} == 0)); then
    printf 'fwdports: SSH leg requires a local or remote forward: %s\n' \
      "$leg_name" >&2
    return 1
  fi
  for value in "$connect_timeout" "$server_alive_interval" \
    "$server_alive_count_max"; do
    [[ -z $value || $value =~ ^[0-9]+$ ]] || {
      printf 'fwdports: SSH numeric option is invalid for leg %s\n' \
        "$leg_name" >&2
      return 1
    }
  done
  for value in "$tcp_keep_alive" "$batch_mode"; do
    [[ -z $value || $value == yes || $value == no ]] || {
      printf 'fwdports: SSH boolean option is invalid for leg %s\n' \
        "$leg_name" >&2
      return 1
    }
  done

  argv=(
    -N
    -T
    -S none
    -o ForkAfterAuthentication=no
    -o ControlPath=none
    -o ControlMaster=no
    -o ControlPersist=no
    -o Tunnel=no
    -o ExitOnForwardFailure=yes
    -o PermitLocalCommand=no
  )
  for value in "${local_forwards[@]}"; do
    argv+=(-L "$value")
  done
  for value in "${remote_forwards[@]}"; do
    argv+=(-R "$value")
  done
  [[ -z $identity_file ]] || argv+=(-i "$identity_file")
  [[ -z $connect_timeout ]] || argv+=(-o "ConnectTimeout=$connect_timeout")
  [[ -z $server_alive_interval ]] ||
    argv+=(-o "ServerAliveInterval=$server_alive_interval")
  [[ -z $server_alive_count_max ]] ||
    argv+=(-o "ServerAliveCountMax=$server_alive_count_max")
  [[ -z $tcp_keep_alive ]] || argv+=(-o "TCPKeepAlive=$tcp_keep_alive")
  [[ -z $batch_mode ]] || argv+=(-o "BatchMode=$batch_mode")

  old_umask=$(umask)
  umask 077
  argv_tmp=$(mktemp "${argv_output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  target_tmp=$(mktemp "${target_output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$argv_tmp"
    return 1
  }
  umask "$old_umask"
  if ! printf '%s\n' "${argv[@]}" >"$argv_tmp" ||
    ! printf '%s\n' "$target" >"$target_tmp" ||
    ! chmod 0600 "$argv_tmp" "$target_tmp"; then
    rm -f -- "$argv_tmp" "$target_tmp"
    return 1
  fi
  # Publish argv last. Callers treat its existence as the completion marker,
  # so a failed target rename can never expose a runnable partial launch.
  if ! mv -f -- "$target_tmp" "$target_output"; then
    rm -f -- "$argv_tmp" "$target_tmp"
    return 1
  fi
  if ! mv -f -- "$argv_tmp" "$argv_output"; then
    rm -f -- "$argv_tmp" "$target_output"
    return 1
  fi
}

fwdports_ssh_prepare_gate() {
  local generation_dir=$1 identity_source=$2 digest_source=$3
  local module_dir template identity_tmp digest_tmp gate_tmp old_umask

  [[ -f "$identity_source" && ! -L "$identity_source" &&
    -f "$digest_source" && ! -L "$digest_source" ]] || {
    printf 'fwdports: SSH gate inputs are unavailable\n' >&2
    return 1
  }
  module_dir=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    return 1
  template=$module_dir/ssh-gate.sh
  [[ -f "$template" && -x "$template" && ! -L "$template" ]] || {
    printf 'fwdports: SSH gate template is unavailable\n' >&2
    return 1
  }

  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$generation_dir" || ! chmod 0700 "$generation_dir"; then
    umask "$old_umask"
    return 1
  fi
  identity_tmp=$(mktemp "$generation_dir/.ssh-identity.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  digest_tmp=$(mktemp "$generation_dir/.ssh-digest.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$identity_tmp"
    return 1
  }
  gate_tmp=$(mktemp "$generation_dir/.ssh-gate.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$identity_tmp" "$digest_tmp"
    return 1
  }
  umask "$old_umask"
  if ! cp -- "$identity_source" "$identity_tmp" ||
    ! cp -- "$digest_source" "$digest_tmp" ||
    ! cp -- "$template" "$gate_tmp" ||
    ! chmod 0600 "$identity_tmp" "$digest_tmp" ||
    ! chmod 0700 "$gate_tmp"; then
    rm -f -- "$identity_tmp" "$digest_tmp" "$gate_tmp"
    return 1
  fi
  # Publish the executable last. Its existence is the generation-local ready
  # marker, so autossh/direct launchers cannot observe half-written inputs.
  if ! mv -f -- "$identity_tmp" "$generation_dir/ssh-identity" ||
    ! mv -f -- "$digest_tmp" "$generation_dir/ssh-digest" ||
    ! mv -f -- "$gate_tmp" "$generation_dir/ssh-gate"; then
    rm -f -- "$identity_tmp" "$digest_tmp" "$gate_tmp" \
      "$generation_dir/ssh-gate"
    return 1
  fi
}

_fwdports_local_forward_port() {
  local spec=$1 first remainder port

  case "$spec" in
    \[*\]:*)
      remainder=${spec#*]}
      remainder=${remainder#:}
      port=${remainder%%:*}
      ;;
    *)
      first=${spec%%:*}
      if [[ $first =~ ^[0-9]+$ ]]; then
        port=$first
      else
        remainder=${spec#*:}
        port=${remainder%%:*}
      fi
      ;;
  esac
  [[ $port =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535)) || return 1
  printf '%s\n' "$port"
}

fwdports_ssh_preflight_local_ports() {
  local argv_file=$1 line expect_local=0 port details status

  [[ -f "$argv_file" && ! -L "$argv_file" ]] || {
    printf 'fwdports: SSH argv file is unavailable\n' >&2
    return 1
  }
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $expect_local -eq 1 ]]; then
      expect_local=0
      port=$(_fwdports_local_forward_port "$line") || {
        printf 'fwdports: cannot parse local-forward port\n' >&2
        return 1
      }
      if command -v lsof >/dev/null 2>&1; then
        if details=$(LC_ALL=C lsof -nP -iTCP:"$port" \
          -sTCP:LISTEN 2>&1); then
          status=0
        else
          status=$?
        fi
        # This function may be sourced by a caller with errexit enabled. It
        # never enables or disables that caller state; the conditional status
        # is captured explicitly and lsof's normal no-match status is benign.
        if [[ $status -eq 0 && -n $details ]]; then
          printf 'fwdports: local forward port %s already has a listener\n' \
            "$port" >&2
          printf 'fwdports: listener details (lsof):\n%s\n' "$details" >&2
          return 1
        fi
        [[ $status -eq 0 || $status -eq 1 ]] || {
          printf 'fwdports: lsof failed while checking local port %s\n' \
            "$port" >&2
          return 1
        }
      elif command -v ss >/dev/null 2>&1; then
        details=$(LC_ALL=C ss -H -ltn "sport = :$port" 2>&1) || {
          printf 'fwdports: ss failed while checking local port %s\n' \
            "$port" >&2
          return 1
        }
        if [[ -n $details ]]; then
          printf 'fwdports: local forward port %s already has a listener\n' \
            "$port" >&2
          printf 'fwdports: listener details (ss):\n%s\n' "$details" >&2
          return 1
        fi
      else
        printf 'fwdports: lsof or ss is required to check local ports\n' >&2
        return 1
      fi
      continue
    fi
    [[ $line == -L ]] && expect_local=1
  done <"$argv_file"
  [[ $expect_local -eq 0 ]] || {
    printf 'fwdports: SSH argv ends inside a local-forward option\n' >&2
    return 1
  }
}

fwdports_ssh_resolve() {
  local requested=$1 output=$2 path stat_record owner mode device inode size
  local mtime version_text version major minor old_umask tmp

  path=$(_fwdports_canonical_executable "$requested") || {
    printf 'fwdports: OpenSSH executable is not available: %s\n' \
      "$requested" >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$path") || {
    printf 'fwdports: cannot identify OpenSSH executable: %s\n' "$path" >&2
    return 1
  }
  read -r owner mode device inode size mtime <<<"$stat_record"
  if [[ $owner != 0 && $owner != "$(id -u)" ]]; then
    printf 'fwdports: OpenSSH executable has an untrusted owner: %s\n' \
      "$path" >&2
    return 1
  fi
  if (((8#$mode & 022) != 0)); then
    printf 'fwdports: OpenSSH executable is group/other writable: %s\n' \
      "$path" >&2
    return 1
  fi

  version_text=$(LC_ALL=C "$path" -V 2>&1) || {
    printf 'fwdports: cannot query OpenSSH version: %s\n' "$path" >&2
    return 1
  }
  if [[ $version_text =~ (OpenSSH_([0-9]+)\.([0-9]+)[^[:space:],]*) ]]; then
    version=${BASH_REMATCH[1]}
    major=${BASH_REMATCH[2]}
    minor=${BASH_REMATCH[3]}
  else
    printf 'fwdports: unrecognized OpenSSH version output: %s\n' "$path" >&2
    return 1
  fi
  if ((major < 7 || (major == 7 && minor < 6))); then
    printf 'fwdports: OpenSSH 7.6 or newer is required: %s\n' "$version" >&2
    return 1
  fi

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    printf 'fwdports: cannot stage OpenSSH identity: %s\n' "$output" >&2
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'path\t%s\n' "$path"
    printf 'identity\t%s:%s:%s:%s:%s\n' \
      "$device" "$inode" "$mode" "$size" "$mtime"
    printf 'version\t%s\n' "$version"
  } >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_autossh_resolve() {
  local requested=$1 output=$2 path stat_record owner mode _rest
  local version_text old_umask tmp

  path=$(_fwdports_canonical_executable "$requested") || {
    printf 'fwdports: autossh is not available\n' >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$path") || return 1
  read -r owner mode _rest <<<"$stat_record"
  if [[ $owner != 0 && $owner != "$(id -u)" ]] ||
    (((8#$mode & 022) != 0)); then
    printf 'fwdports: autossh executable has untrusted metadata\n' >&2
    return 1
  fi
  version_text=$(LC_ALL=C "$path" -V 2>&1) || {
    printf 'fwdports: cannot query autossh version\n' >&2
    return 1
  }
  [[ $version_text == *autossh* ]] || {
    printf 'fwdports: unrecognized autossh version output\n' >&2
    return 1
  }
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'path\t%s\n' "$path"
    printf 'version\t%s\n' "$version_text"
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output";
  then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_builtin_prepare() {
  local manifest=$1 leg=$2 driver=$3 runtime=$4 target_override=$5
  local identity=$runtime/ssh-source argv_file=$runtime/ssh-argv
  local target=$runtime/ssh-target digest=$runtime/ssh-effective-digest
  local kind_file=$runtime/driver-kind tmp old_umask

  [[ $driver == ssh || $driver == autossh ]] || return 1
  [[ -d "$runtime" && ! -L "$runtime" ]] || return 1
  fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" "$identity" ||
    return 1
  fwdports_ssh_build_argv "$manifest" "$leg" "$target_override" \
    "$argv_file" \
    "$target" || return 1
  fwdports_ssh_preflight_local_ports "$argv_file" || return 1
  local ssh_path
  ssh_path=$(LC_ALL=C sed -n 's/^path\t//p' "$identity") || return 1
  [[ -n $ssh_path ]] || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$(<"$target")" "$argv_file" \
    "$digest" || return 1
  fwdports_ssh_prepare_gate "$runtime" "$identity" "$digest" || return 1
  if [[ $driver == autossh ]]; then
    fwdports_autossh_resolve "${FWDPORTS_AUTOSSH_COMMAND:-autossh}" \
      "$runtime/autossh-source" || return 1
  fi

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$runtime/.driver-kind.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! printf '%s\n' "$driver" >"$tmp" || ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$kind_file"; then
    rm -f -- "$tmp"
    return 1
  fi
}
