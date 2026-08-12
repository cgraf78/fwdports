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
  _fwdports_executable_parent_chain_trusted "$candidate" || return 1
  printf '%s\n' "$candidate"
}

_fwdports_executable_parent_chain_trusted() {
  local path=$1 directory record owner mode _rest mode_bits uid parent
  local trust_anchor='' canonical_candidate

  directory=${path%/*}
  uid=$(id -u) || return 1

  # Android's app sandbox is not expressible through traditional owner/mode
  # bits above Termux's PREFIX. Only the real Termux environment gets that
  # platform boundary; a caller-controlled PREFIX on ordinary Unix must not
  # excuse a writable ancestor.
  if _fwdports_termux_prefix_anchor; then
    canonical_candidate=$(cd -P -- "$PREFIX" 2>/dev/null && pwd -P) ||
      return 1
    case "$directory" in
      "$canonical_candidate" | "$canonical_candidate"/*)
        trust_anchor=$canonical_candidate
        ;;
    esac
  fi
  while :; do
    [[ -d $directory && ! -L $directory ]] || {
      printf 'fwdports: executable path has an untrusted parent\n' >&2
      return 1
    }
    record=$(_fwdports_stat_identity "$directory") || return 1
    read -r owner mode _rest <<<"$record"
    [[ $owner =~ ^[0-9]+$ && $mode =~ ^[0-7]{3,4}$ ]] || {
      printf 'fwdports: executable path has an untrusted parent\n' >&2
      return 1
    }
    [[ $owner == 0 || $owner == "$uid" ]] || {
      printf 'fwdports: executable path has an untrusted parent\n' >&2
      return 1
    }
    mode_bits=$((8#$mode))
    if (((mode_bits & 022) != 0)); then
      # A trusted-owner sticky directory such as /tmp prevents another UID
      # from replacing this user's entry. Other writable ancestors leave a
      # cross-UID rename seam between the launch gate's hash and exec.
      (((mode_bits & 01000) != 0)) || {
        printf 'fwdports: executable path has an untrusted parent\n' >&2
        return 1
      }
    fi
    [[ -z $trust_anchor || $directory != "$trust_anchor" ]] || break
    [[ $directory != / ]] || break
    parent=${directory%/*}
    [[ -n $parent ]] || parent=/
    directory=$parent
  done
}

_fwdports_termux_prefix_anchor() {
  # OSTYPE is compiled into Bash and remains available to run-as, cron, and CI
  # shells that do not inherit Termux's interactive TERMUX_VERSION variable.
  [[ ${OSTYPE:-} == linux-android* ]] || return 1
  case ${PREFIX:-} in
    /data/data/*/files/usr) return 0 ;;
    *) return 1 ;;
  esac
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
  local policy=${5:-ssh}
  local output_dir old_umask baseline raw normalized stderr_file digest tmp
  local line status index skip=0 keyword remainder ambient_error=''
  local -a argv=() probe_argv=()

  [[ $policy == ssh || $policy == et ]] || {
    printf 'fwdports: invalid SSH configuration policy\n' >&2
    return 1
  }
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
  if [[ -n ${argv[0]+set} ]]; then
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
  fi
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
      forwardagent)
        if [[ $policy == et && $remainder == yes ]]; then
          ambient_error='ambient SSH agent forwarding is not allowed for ET'
          break
        fi
        ;;
      setenv)
        if [[ $policy == et ]]; then
          ambient_error='ambient SSH SetEnv is not allowed for ET'
          break
        fi
        ;;
      proxyjump | proxycommand)
        if [[ $policy == et && -n $remainder && $remainder != none ]]; then
          # ET consumes jump routing itself and launches a second, materially
          # different SSH command. Supporting that safely needs two separately
          # bound targets, so the first built-in deliberately stays direct.
          ambient_error='ambient SSH proxy routing is not supported for ET'
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

_fwdports_et_forward_record() {
  local spec=$1 endpoint
  local source_host source_port destination_host destination_port

  # Keep ET's use of the standard manifest key narrower than the transport's
  # complete grammar. Four explicit network fields have the same meaning for
  # OpenSSH and ET; ranges, sockets, omitted bind addresses, and ET's two-part
  # shorthand would otherwise make one supposedly portable record ambiguous.
  endpoint='(\[[0-9A-Fa-f:.%]+\]|[A-Za-z0-9._%-]+)'
  # Bound width before arithmetic. Bash arithmetic wraps huge integers, which
  # could otherwise turn an invalid decimal into a value below 65536.
  [[ $spec != -* &&
    $spec =~ ^${endpoint}:([1-9][0-9]{0,4}):${endpoint}:([1-9][0-9]{0,4})$ ]] ||
    return 1
  source_host=${BASH_REMATCH[1]}
  source_port=${BASH_REMATCH[2]}
  destination_host=${BASH_REMATCH[3]}
  destination_port=${BASH_REMATCH[4]}
  ((10#$source_port <= 65535 && 10#$destination_port <= 65535)) || return 1
  printf '%s\t%s\t%s\t%s\n' "$source_host" "$source_port" \
    "$destination_host" "$destination_port"
}

_fwdports_ssh_safe_forward() {
  # Keep SSH deliberately narrower than OpenSSH's complete grammar while
  # preserving its ordinary three- and four-part TCP forwarding forms.
  # Whitespace, option-looking values, sockets, and expansion tokens remain
  # excluded so every record is one unambiguous argv element.
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
  if [[ -z ${local_forwards[0]+set} && -z ${remote_forwards[0]+set} ]]; then
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
  for value in ${local_forwards[@]+"${local_forwards[@]}"}; do
    argv+=(-L "$value")
  done
  for value in ${remote_forwards[@]+"${remote_forwards[@]}"}; do
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
  # Width-bound before arithmetic: Bash wraps huge decimal strings. Preserve
  # ordinary leading-zero SSH syntax while interpreting the value in base 10.
  [[ $port =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$port >= 1 && 10#$port <= 65535)) || return 1
  printf '%s\n' "$port"
}

fwdports_builtin_validate_profile_ports() {
  local manifest=$1 kind leg key value _extra driver candidate port seen
  local -a builtin_legs=() seen_ports=()

  [[ -f $manifest && ! -L $manifest ]] || return 1
  while IFS=$'\t' read -r kind leg driver _extra || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    fwdports_driver_is_builtin "$driver" && builtin_legs+=("$leg")
  done <"$manifest"

  while IFS=$'\t' read -r kind leg key value _extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == set && $key == local-forward ]] || continue
    candidate=0
    for driver in ${builtin_legs[@]+"${builtin_legs[@]}"}; do
      [[ $driver == "$leg" ]] && candidate=1
    done
    [[ $candidate -eq 1 ]] || continue
    port=$(_fwdports_local_forward_port "$value") || {
      printf 'fwdports: cannot parse local-forward port for leg %s\n' \
        "$leg" >&2
      return 1
    }
    seen=0
    for candidate in ${seen_ports[@]+"${seen_ports[@]}"}; do
      [[ $candidate == "$port" ]] && seen=1
    done
    if [[ $seen -eq 1 ]]; then
      # Built-in legs share the local network namespace. Rejecting duplicate
      # numeric ports before any pane starts is deliberately conservative:
      # relying on bind-address subtleties can leave one retrying leg masked
      # by another leg's successful health probe.
      printf 'fwdports: local forward port %s is claimed more than once\n' \
        "$port" >&2
      return 1
    fi
    seen_ports+=("$port")
  done <"$manifest"
}

_fwdports_preflight_local_forward() {
  local spec=$1 port details status

  port=$(_fwdports_local_forward_port "$spec") || {
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
    # This function may be sourced by a caller with errexit enabled. It never
    # enables or disables that caller state; lsof's no-match status is benign.
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
    # Android/Termux can deny lsof access to another app process even when
    # both processes share the loopback network namespace. A bounded probe
    # closes that visibility gap; the transport remains final bind authority.
    if [[ ($status -eq 1 || -z $details) ]] &&
      command -v nc >/dev/null 2>&1 &&
      nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
      printf 'fwdports: local forward port %s already has a listener\n' \
        "$port" >&2
      printf '%s\n' \
        'fwdports: listener details (nc): loopback connection succeeded' >&2
      return 1
    fi
  elif command -v ss >/dev/null 2>&1; then
    details=$(LC_ALL=C ss -H -ltn "sport = :$port" 2>&1) || {
      printf 'fwdports: ss failed while checking local port %s\n' "$port" >&2
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
}

fwdports_ssh_preflight_local_ports() {
  local argv_file=$1 line expect_local=0

  [[ -f "$argv_file" && ! -L "$argv_file" ]] || {
    printf 'fwdports: SSH argv file is unavailable\n' >&2
    return 1
  }
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $expect_local -eq 1 ]]; then
      expect_local=0
      _fwdports_preflight_local_forward "$line" || return 1
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

_fwdports_write_private_lines() {
  local output=$1 output_dir old_umask tmp
  shift

  output_dir=${output%/*}
  [[ $output_dir != "$output" && -d $output_dir && ! -L $output_dir ]] ||
    return 1
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$output_dir/.${output##*/}.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" >"$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  else
    : >"$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_et_resolve() {
  local requested=$1 output=$2 path stat_record owner mode device inode size
  local mtime version_text version major minor patch help_text capability digest
  local old_umask tmp

  path=$(_fwdports_canonical_executable "$requested") || {
    printf 'fwdports: Eternal Terminal executable is not available: %s\n' \
      "$requested" >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$path") || {
    printf 'fwdports: cannot identify Eternal Terminal executable\n' >&2
    return 1
  }
  read -r owner mode device inode size mtime <<<"$stat_record"
  if [[ $owner != 0 && $owner != "$(id -u)" ]]; then
    printf 'fwdports: Eternal Terminal executable has an untrusted owner\n' >&2
    return 1
  fi
  if (((8#$mode & 022) != 0)); then
    printf '%s\n' \
      'fwdports: Eternal Terminal executable is group/other writable' >&2
    return 1
  fi

  version_text=$(LC_ALL=C "$path" --version 2>&1) || {
    printf 'fwdports: cannot query Eternal Terminal version\n' >&2
    return 1
  }
  if [[ $version_text =~ ^et[[:space:]]+version[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
    version=$major.$minor.$patch
  else
    printf 'fwdports: unrecognized Eternal Terminal version output\n' >&2
    return 1
  fi
  # The private SSH interception contract is based on tagged 7.0.0 source,
  # not merely public flags. Even a later patch can change PATH lookup or the
  # bootstrap argv shape, so each newly supported release needs fresh proof.
  if [[ $version != 7.0.0 ]]; then
    printf 'fwdports: ET 7.0.0 is required (found %s)\n' "$version" >&2
    return 1
  fi
  help_text=$(LC_ALL=C "$path" --help 2>&1) || {
    printf 'fwdports: cannot query Eternal Terminal capabilities\n' >&2
    return 1
  }
  for capability in --port --tunnel --reversetunnel --logdir \
    --logtostdout --no-terminal --telemetry; do
    [[ $help_text == *"$capability"* ]] || {
      printf 'fwdports: Eternal Terminal lacks required option %s\n' \
        "$capability" >&2
      return 1
    }
  done
  digest=$(_fwdports_sha256_file "$path") || {
    printf 'fwdports: cannot hash Eternal Terminal executable\n' >&2
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
    printf 'identity\t%s:%s:%s:%s:%s\n' \
      "$device" "$inode" "$mode" "$size" "$mtime"
    printf 'digest\t%s\n' "$digest"
    printf 'version\t%s\n' "$version"
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fwdports_et_safe_target() {
  local target=$1 host

  _fwdports_ssh_safe_target "$target" || return 1
  case "$target" in
    @* | *@*@*) return 1 ;;
  esac
  host=${target##*@}
  [[ -n $host ]] || return 1
  case "$host" in
    \[* | *\]) return 1 ;;
  esac
  # Stock ET gives colon counts several meanings, including an inline ET port
  # on a fully expanded IPv6 literal. Deferring raw literals avoids preparing
  # SSH gates for a target that ET will later rewrite. An SSH alias may still
  # resolve to IPv6 without crossing this text-parsing boundary.
  [[ $host != *:* ]]
}

_fwdports_et_local_forward_has_check() {
  local manifest=$1 leg_name=$2 spec=$3 record bind_host bind_port _
  local kind leg probe_type host port _label _extra

  record=$(_fwdports_et_forward_record "$spec") || return 1
  IFS=$'\t' read -r bind_host bind_port _ <<<"$record"
  while IFS=$'\t' read -r kind leg probe_type host port _label _extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == check && $leg == "$leg_name" ]] || continue
    case "$probe_type" in loopback | tcp) ;; *) continue ;; esac
    [[ $host == "$bind_host" && $port == "$bind_port" ]] && return 0
  done <"$manifest"
  printf 'fwdports: ET local-forward for leg %s requires a matching check\n' \
    "$leg_name" >&2
  return 1
}

fwdports_et_build_argv() {
  local manifest=$1 leg_name=$2 target_override=$3 argv_output=$4
  local target_output=$5 log_dir=$6
  local kind leg key value _extra driver='' host='' port='' target
  local old_umask argv_tmp target_tmp log_parent
  local -a local_forwards=() remote_forwards=() argv=()

  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    printf 'fwdports: resolved manifest is unavailable\n' >&2
    return 1
  }
  while IFS=$'\t' read -r kind leg key value _extra || [[ -n ${kind:-} ]]; do
    case "$kind" in
      leg)
        [[ $leg != "$leg_name" ]] || driver=$key
        ;;
      set)
        [[ $leg == "$leg_name" ]] || continue
        case "$key" in
          host) host=$value ;;
          port) port=$value ;;
          local-forward)
            _fwdports_et_forward_record "$value" >/dev/null || {
              printf 'fwdports: ET local-forward must use four-part network syntax\n' >&2
              return 1
            }
            [[ -z ${local_forwards[0]+set} ]] || {
              printf 'fwdports: ET supports at most one local-forward per leg\n' >&2
              return 1
            }
            local_forwards+=("$value")
            ;;
          remote-forward)
            _fwdports_et_forward_record "$value" >/dev/null || {
              printf 'fwdports: ET remote-forward must use four-part network syntax\n' >&2
              return 1
            }
            [[ -z ${remote_forwards[0]+set} ]] || {
              printf 'fwdports: ET supports at most one remote-forward per leg\n' >&2
              return 1
            }
            remote_forwards+=("$value")
            ;;
          *)
            printf 'fwdports: unknown ET key for leg %s: %s\n' \
              "$leg_name" "$key" >&2
            return 1
            ;;
        esac
        ;;
    esac
  done <"$manifest"

  [[ $driver == et ]] || {
    printf 'fwdports: leg is not an ET driver: %s\n' "$leg_name" >&2
    return 1
  }
  target=${target_override:-$host}
  _fwdports_et_safe_target "$target" || {
    if [[ $target == *:* && ${target##*@} != *:*:* ]]; then
      printf 'fwdports: use the separate port key for ET server ports\n' >&2
    else
      printf 'fwdports: ET host is missing or unsafe for leg %s\n' \
        "$leg_name" >&2
    fi
    return 1
  }
  if [[ -n $port ]]; then
    # Bound width before arithmetic because Bash wraps huge integer literals.
    if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || ((10#$port > 65535)); then
      printf 'fwdports: ET port is invalid for leg %s\n' "$leg_name" >&2
      return 1
    fi
  fi
  [[ -n ${local_forwards[0]+set} || -n ${remote_forwards[0]+set} ]] || {
    printf 'fwdports: ET leg requires a local or remote forward: %s\n' \
      "$leg_name" >&2
    return 1
  }
  if [[ -n ${local_forwards[0]+set} ]]; then
    _fwdports_et_local_forward_has_check "$manifest" "$leg_name" \
      "${local_forwards[0]}" || return 1
  fi

  log_parent=${log_dir%/*}
  [[ $log_dir == /* && $log_parent != "$log_dir" &&
    -d $log_parent && ! -L $log_parent ]] || {
    printf 'fwdports: ET log parent is unavailable\n' >&2
    return 1
  }
  if [[ -e $log_dir || -L $log_dir ]]; then
    [[ -d $log_dir && ! -L $log_dir ]] || {
      printf 'fwdports: ET log path is not a private directory\n' >&2
      return 1
    }
  else
    mkdir "$log_dir" || return 1
  fi
  chmod 0700 "$log_dir" || return 1

  argv=(--no-terminal --logdir "$log_dir" --logtostdout --telemetry=false)
  [[ -z $port ]] || argv+=(--port "$port")
  [[ -z ${local_forwards[0]+set} ]] ||
    argv+=(--tunnel "${local_forwards[0]}")
  [[ -z ${remote_forwards[0]+set} ]] ||
    argv+=(--reversetunnel "${remote_forwards[0]}")

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
  # Match the SSH publication contract: argv is the completion marker, and a
  # failed second rename removes the already-published target.
  if ! mv -f -- "$target_tmp" "$target_output"; then
    rm -f -- "$argv_tmp" "$target_tmp"
    return 1
  fi
  if ! mv -f -- "$argv_tmp" "$argv_output"; then
    rm -f -- "$argv_tmp" "$target_output"
    return 1
  fi
}

fwdports_et_write_ssh_argv() {
  local output=$1

  # These options constrain the OpenSSH bootstrap that ET uses to start its
  # server helper. ET's own data tunnels remain the manifest-owned forwards.
  _fwdports_write_private_lines "$output" \
    -S none \
    -T \
    -o ClearAllForwardings=yes \
    -o PermitLocalCommand=no \
    -o RemoteCommand=none \
    -o ControlMaster=no \
    -o ControlPath=none \
    -o ControlPersist=no \
    -o ForkAfterAuthentication=no \
    -o Tunnel=no \
    -o ForwardAgent=no
}

fwdports_et_preflight_local_ports() {
  local manifest=$1 leg_name=$2 kind leg key value _extra

  while IFS=$'\t' read -r kind leg key value _extra || [[ -n ${kind:-} ]]; do
    [[ $kind == set && $leg == "$leg_name" && $key == local-forward ]] ||
      continue
    _fwdports_preflight_local_forward "$value" || return 1
  done <"$manifest"
}

fwdports_et_prepare_runtime() {
  local runtime=$1 module_dir et_template shim_template et_tmp shim_tmp
  local bin_dir=$runtime/et-bin temp_dir=$runtime/et-tmp old_umask

  module_dir=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    return 1
  et_template=$module_dir/et-gate.sh
  shim_template=$module_dir/et-ssh-wrapper.sh
  [[ -f $et_template && -x $et_template && ! -L $et_template &&
    -f $shim_template && -x $shim_template && ! -L $shim_template ]] || {
    printf 'fwdports: stock ET gate templates are unavailable\n' >&2
    return 1
  }

  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$bin_dir" "$temp_dir" ||
    ! chmod 0700 "$bin_dir" "$temp_dir"; then
    umask "$old_umask"
    return 1
  fi
  et_tmp=$(mktemp "$runtime/.et-gate.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  shim_tmp=$(mktemp "$bin_dir/.ssh.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$et_tmp"
    return 1
  }
  umask "$old_umask"
  if ! cp -- "$et_template" "$et_tmp" ||
    ! cp -- "$shim_template" "$shim_tmp" ||
    ! chmod 0700 "$et_tmp" "$shim_tmp"; then
    rm -f -- "$et_tmp" "$shim_tmp"
    return 1
  fi
  # Publish the shim before the ET gate. The latter is the complete-runtime
  # marker and must never become executable while its PATH entry is partial.
  if ! mv -f -- "$shim_tmp" "$bin_dir/ssh" ||
    ! mv -f -- "$et_tmp" "$runtime/et-gate"; then
    rm -f -- "$shim_tmp" "$et_tmp" "$runtime/et-gate"
    return 1
  fi
}

_fwdports_builtin_prepare_ssh() {
  local manifest=$1 leg=$2 driver=$3 runtime=$4 target_override=$5
  local identity=$runtime/ssh-source argv_file=$runtime/ssh-argv
  local target=$runtime/ssh-target digest=$runtime/ssh-effective-digest
  local ssh_path

  fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" "$identity" ||
    return 1
  fwdports_ssh_build_argv "$manifest" "$leg" "$target_override" \
    "$argv_file" "$target" || return 1
  fwdports_ssh_preflight_local_ports "$argv_file" || return 1
  ssh_path=$(LC_ALL=C sed -n 's/^path\t//p' "$identity") || return 1
  [[ -n $ssh_path ]] || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$(<"$target")" "$argv_file" \
    "$digest" || return 1
  fwdports_ssh_prepare_gate "$runtime" "$identity" "$digest" || return 1
  if [[ $driver == autossh ]]; then
    fwdports_autossh_resolve "${FWDPORTS_AUTOSSH_COMMAND:-autossh}" \
      "$runtime/autossh-source" || return 1
  fi
}

_fwdports_builtin_prepare_et() {
  local manifest=$1 leg=$2 runtime=$3 target_override=$4 ssh_path
  local et_source=$runtime/et-source et_argv=$runtime/et-argv
  local et_target=$runtime/et-target et_log=$runtime/et-log
  local ssh_source=$runtime/et-ssh-source
  local ambient_argv=$runtime/et-ssh-ambient-argv
  local ambient_digest=$runtime/et-ssh-ambient-digest
  local bootstrap_argv=$runtime/et-ssh-argv
  local bootstrap_digest=$runtime/et-ssh-bootstrap-digest

  fwdports_et_resolve "${FWDPORTS_ET_COMMAND:-et}" "$et_source" || return 1
  fwdports_et_build_argv "$manifest" "$leg" "$target_override" \
    "$et_argv" "$et_target" "$et_log" || return 1
  fwdports_et_preflight_local_ports "$manifest" "$leg" || return 1

  # ET invokes an ambient command literally named `ssh`. Resolve the same
  # trusted executable as the SSH built-ins, then route ET through private
  # generation gates rather than whichever PATH entry appears later.
  fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" "$ssh_source" ||
    return 1
  ssh_path=$(LC_ALL=C sed -n 's/^path\t//p' "$ssh_source") || return 1
  [[ -n $ssh_path ]] || return 1

  _fwdports_write_private_lines "$ambient_argv" || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$(<"$et_target")" \
    "$ambient_argv" "$ambient_digest" et || return 1
  fwdports_ssh_prepare_gate "$runtime/et-ssh-ambient" "$ssh_source" \
    "$ambient_digest" || return 1

  fwdports_et_write_ssh_argv "$bootstrap_argv" || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$(<"$et_target")" \
    "$bootstrap_argv" "$bootstrap_digest" || return 1
  fwdports_ssh_prepare_gate "$runtime/et-ssh-bootstrap" "$ssh_source" \
    "$bootstrap_digest" || return 1
  fwdports_et_prepare_runtime "$runtime"
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
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fwdports_builtin_prepare() {
  local manifest=$1 leg=$2 driver=$3 runtime=$4 target_override=$5
  local kind_file=$runtime/driver-kind tmp old_umask

  fwdports_driver_is_builtin "$driver" || return 1
  [[ -d "$runtime" && ! -L "$runtime" ]] || return 1
  case "$driver" in
    ssh | autossh)
      _fwdports_builtin_prepare_ssh "$manifest" "$leg" "$driver" \
        "$runtime" "$target_override" || return 1
      ;;
    et)
      _fwdports_builtin_prepare_et "$manifest" "$leg" "$runtime" \
        "$target_override" || return 1
      ;;
  esac

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
