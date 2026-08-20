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

_fwdports_stat_group() {
  local path=$1 output

  if output=$(LC_ALL=C stat -c '%g' -- "$path" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  if output=$(LC_ALL=C stat -f '%g' "$path" 2>/dev/null); then
    printf '%s\n' "$output"
    return 0
  fi
  return 1
}

_fwdports_platform_is_darwin() {
  [[ ${OSTYPE:-} == darwin* ]]
}

_fwdports_darwin_group_parent_trusted() {
  local directory=$1 mode_bits=$2 group memberships

  _fwdports_platform_is_darwin || return 1
  # Standard macOS application and package-manager roots are commonly 0775
  # for the admin group. Local admins already share a root-capable trust
  # boundary; other-write remains outside it.
  (((mode_bits & 020) != 0 && (mode_bits & 002) == 0)) || return 1
  group=$(_fwdports_stat_group "$directory") || return 1
  # macOS reserves gid 80 for the local admin group.
  [[ $group == 80 ]] || return 1
  memberships=$(id -G) || return 1
  [[ $memberships =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]] || return 1
  [[ " $memberships " == *" $group "* ]]
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
    # The helper succeeds only in Termux, where PREFIX is an ambient contract.
    # shellcheck disable=SC2153
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
      printf 'fwdports: executable path has an untrusted parent: %s\n' \
        "$directory" >&2
      return 1
    }
    record=$(_fwdports_stat_identity "$directory") || {
      printf 'fwdports: executable path has an untrusted parent: %s\n' \
        "$directory" >&2
      return 1
    }
    read -r owner mode _rest <<<"$record"
    [[ $owner =~ ^[0-9]+$ && $mode =~ ^[0-7]{3,4}$ ]] || {
      printf 'fwdports: executable path has an untrusted parent: %s\n' \
        "$directory" >&2
      return 1
    }
    [[ $owner == 0 || $owner == "$uid" ]] || {
      printf 'fwdports: executable path has an untrusted parent: %s (owner %s)\n' \
        "$directory" "$owner" >&2
      return 1
    }
    mode_bits=$((8#$mode))
    if (((mode_bits & 022) != 0)); then
      # A trusted-owner sticky directory such as /tmp prevents another UID
      # from replacing this user's entry. Darwin's explicit group rule treats
      # the caller's root-capable local group as trusted; other writable
      # ancestors leave a cross-UID rename seam between the hash and exec.
      if (((mode_bits & 01000) != 0)) ||
        _fwdports_darwin_group_parent_trusted "$directory" "$mode_bits"; then
        :
      else
        printf 'fwdports: executable path has an untrusted parent: %s (mode %s)\n' \
          "$directory" "$mode" >&2
        return 1
      fi
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

  [[ $policy == ssh || $policy == et || $policy == et-proxy ]] || {
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
        if [[ $policy == et* && $remainder == yes ]]; then
          ambient_error='ambient SSH agent forwarding is not allowed for ET'
          break
        fi
        ;;
      setenv)
        if [[ $policy == et* ]]; then
          ambient_error='ambient SSH SetEnv is not allowed for ET'
          break
        fi
        ;;
      proxyjump)
        if [[ $policy == et && -n $remainder && $remainder != none ]]; then
          # Callers must first resolve and bind ET's destination and jump-host
          # call shapes. A plain ET policy has no such route plan.
          ambient_error='ambient SSH proxy routing is not supported for ET'
          break
        fi
        ;;
      proxycommand)
        if [[ $policy == et* && -n $remainder && $remainder != none ]]; then
          ambient_error='ambient SSH proxy commands are not supported for ET'
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

_fwdports_et_proxyjump_plan() {
  local ssh_path=$1 target=$2 output=$3 output_dir old_umask raw jump_raw tmp
  local keyword remainder target_user='' proxyjump='' proxycommand=''
  local jump_user='' jump_hostname='' jump_port='' jump_proxyjump=''
  local jump_proxycommand='' destination_endpoint jump_endpoint

  output_dir=${output%/*}
  [[ $output_dir != "$output" && -d $output_dir && ! -L $output_dir ]] ||
    return 1
  old_umask=$(umask)
  umask 077
  raw=$(mktemp "$output_dir/.et-ssh-target.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  jump_raw=$(mktemp "$output_dir/.et-ssh-jump.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$raw"
    return 1
  }
  tmp=$(mktemp "$output_dir/.${output##*/}.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$raw" "$jump_raw"
    return 1
  }
  umask "$old_umask"

  if ! LC_ALL=C "$ssh_path" -G "$target" >"$raw" 2>/dev/null; then
    rm -f -- "$raw" "$jump_raw" "$tmp"
    printf 'fwdports: OpenSSH ProxyJump configuration failed\n' >&2
    return 1
  fi
  while read -r keyword remainder; do
    case "$keyword" in
      user) target_user=$remainder ;;
      proxyjump) proxyjump=$remainder ;;
      proxycommand) proxycommand=$remainder ;;
    esac
  done <"$raw"
  if [[ -z $proxyjump || $proxyjump == none ]]; then
    rm -f -- "$raw" "$jump_raw"
    if ! : >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
      rm -f -- "$tmp"
      return 1
    fi
    return 0
  fi
  if [[ -n $proxycommand && $proxycommand != none ]]; then
    rm -f -- "$raw" "$jump_raw" "$tmp"
    printf 'fwdports: ET ProxyJump cannot be combined with ProxyCommand\n' >&2
    return 1
  fi
  if [[ ! $proxyjump =~ ^[A-Za-z0-9_.-]+$ ]]; then
    rm -f -- "$raw" "$jump_raw" "$tmp"
    printf 'fwdports: ET supports one ProxyJump SSH alias\n' >&2
    return 1
  fi
  if [[ ! $target_user =~ ^[A-Za-z0-9._-]+$ ]]; then
    rm -f -- "$raw" "$jump_raw" "$tmp"
    printf 'fwdports: ET ProxyJump destination user is unsupported\n' >&2
    return 1
  fi

  if ! LC_ALL=C "$ssh_path" -G "$proxyjump" >"$jump_raw" 2>/dev/null; then
    rm -f -- "$raw" "$jump_raw" "$tmp"
    printf 'fwdports: OpenSSH jump-host configuration failed\n' >&2
    return 1
  fi
  while read -r keyword remainder; do
    case "$keyword" in
      user) jump_user=$remainder ;;
      hostname) jump_hostname=$remainder ;;
      port) jump_port=$remainder ;;
      proxyjump) jump_proxyjump=$remainder ;;
      proxycommand) jump_proxycommand=$remainder ;;
    esac
  done <"$jump_raw"
  rm -f -- "$raw" "$jump_raw"

  if [[ -n $jump_proxyjump && $jump_proxyjump != none ]] ||
    [[ -n $jump_proxycommand && $jump_proxycommand != none ]]; then
    rm -f -- "$tmp"
    printf 'fwdports: nested ET ProxyJump routing is not supported\n' >&2
    return 1
  fi
  if [[ ! $jump_user =~ ^[A-Za-z0-9._-]+$ ||
    ! $jump_hostname =~ ^[A-Za-z0-9._%-]+$ || $jump_port != 22 ]]; then
    rm -f -- "$tmp"
    printf 'fwdports: ET ProxyJump endpoint is unsupported\n' >&2
    return 1
  fi

  case "$target" in
    *@*) destination_endpoint=$target ;;
    *) destination_endpoint=$target_user@$target ;;
  esac
  jump_endpoint=$jump_user@$jump_hostname
  if ! printf '%s\n' \
    $'target\t'"$target" \
    $'destination\t'"$destination_endpoint" \
    $'jump-selector\t'"$proxyjump" \
    $'jump-endpoint\t'"$jump_endpoint" >"$tmp" ||
    ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
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

_fwdports_ettun_safe_via() {
  [[ $1 =~ ^[[:alnum:]_][[:alnum:]_.@:-]*$ ]]
}

_fwdports_ettun_safe_destination() {
  [[ $1 =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]]
}

_fwdports_ettun_assign_remote_port_slot() {
  local manifest=$1 requested_leg=$2 output=$3
  local digest prefix origin kind leg key value _extra
  local source_port destination_port port slot
  local cursor candidate probe selected
  local -a forbidden=() used=()

  [[ -f $manifest && ! -L $manifest ]] || return 1
  digest=$(_fwdports_sha256_file "$manifest") || return 1
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  prefix=${digest:0:4}
  origin=$((16#$prefix % 819))

  # Every generated port for one slot has the same residue modulo 819. Generated
  # listeners exist on both sides of the transport, so reserve both endpoints
  # of every declared route before assigning a leg. This prevents a generated
  # control/data listener from preempting a fixed service that starts later.
  while IFS=$'\t' read -r kind leg key value _extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == set &&
      ($key == local-forward || $key == remote-forward) ]] || continue
    source_port=$(_fwdports_local_forward_port "$value") || continue
    destination_port=${value##*:}
    if [[ ! $destination_port =~ ^[0-9]{1,5}$ ]] ||
      ((10#$destination_port < 1 || 10#$destination_port > 65535)); then
      destination_port=''
    fi
    for port in "$source_port" "$destination_port"; do
      [[ -n $port ]] || continue
      port=$((10#$port))
      ((port >= 49152 && port <= 65531)) || continue
      slot=$(((port - 49152) % 819))
      forbidden[slot]=1
    done
  done <"$manifest"

  # Assign without replacement in canonical manifest order. The digest-derived
  # origin avoids making one slot a permanent hot spot while open addressing
  # makes the result independent of per-leg preparation order.
  cursor=$origin
  while IFS=$'\t' read -r kind leg key _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg && $key == ettun ]] || continue
    selected=-1
    for ((probe = 0; probe < 819; probe++)); do
      candidate=$(((cursor + probe) % 819))
      [[ ${forbidden[$candidate]:-0} -eq 0 &&
        ${used[$candidate]:-0} -eq 0 ]] || continue
      selected=$candidate
      break
    done
    if ((selected < 0)); then
      printf '%s\n' \
        'fwdports: no remote port slot is available for ettun legs' >&2
      return 1
    fi
    used[selected]=1
    cursor=$(((selected + 1) % 819))
    [[ $leg == "$requested_leg" ]] || continue
    _fwdports_write_private_lines "$output" "$selected"
    return
  done <"$manifest"

  printf 'fwdports: ettun leg is unavailable for remote port assignment: %s\n' \
    "$requested_leg" >&2
  return 1
}

_fwdports_ettun_local_forward_has_check() {
  local manifest=$1 leg_name=$2 bind_host=$3 bind_port=$4
  local kind leg probe_type host port _label _extra

  while IFS=$'\t' read -r kind leg probe_type host port _label _extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == check && $leg == "$leg_name" ]] || continue
    case "$probe_type" in loopback | tcp) ;; *) continue ;; esac
    [[ $host == "$bind_host" && $port == "$bind_port" ]] && return 0
  done <"$manifest"
  printf 'fwdports: ettun local-forward for leg %s requires a matching check\n' \
    "$leg_name" >&2
  return 1
}

fwdports_ettun_build_argv() {
  local manifest=$1 leg_name=$2 target_override=$3 argv_output=$4
  local transport_output=${5:-}
  local kind leg key value _extra driver='' host='' local_forward=''
  local remote_forward='' transport=''
  local via record bind_host bind_port destination_host destination_port
  local reverse_bind_host reverse_bind_port reverse_host reverse_port
  local -a route_argv=()

  [[ -f $manifest && ! -L $manifest ]] || {
    printf 'fwdports: resolved manifest is unavailable\n' >&2
    return 1
  }
  while IFS=$'\t' read -r kind leg key value _extra ||
    [[ -n ${kind:-} ]]; do
    case "$kind" in
      leg)
        [[ $leg != "$leg_name" ]] || driver=$key
        ;;
      set)
        [[ $leg == "$leg_name" ]] || continue
        case "$key" in
          host) host=$value ;;
          transport)
            [[ -z $transport ]] || {
              printf 'fwdports: ettun accepts at most one transport per leg\n' \
                >&2
              return 1
            }
            transport=$value
            ;;
          local-forward)
            [[ -z $local_forward ]] || {
              printf 'fwdports: ettun requires exactly one local-forward per leg\n' >&2
              return 1
            }
            local_forward=$value
            ;;
          remote-forward)
            [[ -z $remote_forward ]] || {
              printf 'fwdports: ettun accepts at most one remote-forward per leg\n' \
                >&2
              return 1
            }
            remote_forward=$value
            ;;
          *)
            printf 'fwdports: unknown ettun key for leg %s: %s\n' \
              "$leg_name" "$key" >&2
            return 1
            ;;
        esac
        ;;
    esac
  done <"$manifest"

  [[ $driver == ettun ]] || {
    printf 'fwdports: leg is not an ettun driver: %s\n' "$leg_name" >&2
    return 1
  }
  via=${target_override:-$host}
  _fwdports_ettun_safe_via "$via" || {
    printf 'fwdports: ettun via host is missing or unsafe for leg %s\n' \
      "$leg_name" >&2
    return 1
  }
  [[ -n $local_forward || -n $remote_forward ]] || {
    printf 'fwdports: ettun requires a local-forward or remote-forward per leg\n' \
      >&2
    return 1
  }
  if [[ -n $local_forward ]]; then
    record=$(_fwdports_et_forward_record "$local_forward") || {
      printf 'fwdports: ettun local-forward must use four-part network syntax\n' >&2
      return 1
    }
    IFS=$'\t' read -r bind_host bind_port destination_host destination_port \
      <<<"$record"
    [[ $bind_host == 127.0.0.1 ]] || {
      printf 'fwdports: ettun local-forward must bind 127.0.0.1\n' >&2
      return 1
    }
    _fwdports_ettun_safe_destination "$destination_host" || {
      printf 'fwdports: ettun destination host is unsafe for leg %s\n' \
        "$leg_name" >&2
      return 1
    }
    _fwdports_ettun_local_forward_has_check "$manifest" "$leg_name" \
      "$bind_host" "$bind_port" || return 1
  fi
  if [[ -n $remote_forward ]]; then
    record=$(_fwdports_et_forward_record "$remote_forward") || {
      printf 'fwdports: ettun remote-forward must use four-part network syntax\n' >&2
      return 1
    }
    IFS=$'\t' read -r reverse_bind_host reverse_bind_port reverse_host \
      reverse_port <<<"$record"
    [[ $reverse_bind_host == 127.0.0.1 ]] || {
      printf 'fwdports: ettun remote-forward must bind 127.0.0.1\n' >&2
      return 1
    }
    _fwdports_ettun_safe_destination "$reverse_host" || {
      printf 'fwdports: ettun reverse destination is unsafe for leg %s\n' \
        "$leg_name" >&2
      return 1
    }
  fi

  if [[ -n $local_forward && -z $remote_forward ]]; then
    # Preserve the original four-line engine contract for local-only profiles.
    route_argv=("$via" "$bind_port" "$destination_host" "$destination_port")
  else
    route_argv=("$via")
    if [[ -n $local_forward ]]; then
      route_argv+=(--local "$bind_port" "$destination_host" "$destination_port")
    fi
    if [[ -n $remote_forward ]]; then
      route_argv+=(--reverse "$reverse_bind_port" "$reverse_host" "$reverse_port")
    fi
  fi
  _fwdports_write_private_lines "$argv_output" "${route_argv[@]}" || return 1
  if [[ -n $transport_output ]]; then
    if [[ -n $transport ]]; then
      _fwdports_write_private_lines "$transport_output" "$transport" || {
        rm -f -- "$argv_output" "$transport_output"
        return 1
      }
    elif ! _fwdports_write_private_lines "$transport_output"; then
      rm -f -- "$argv_output" "$transport_output"
      return 1
    fi
  fi
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

_fwdports_ettun_command_path() {
  command -v "$1" 2>/dev/null
}

_fwdports_ettun_platform_is_darwin() {
  _fwdports_platform_is_darwin
}

_fwdports_ettun_session_enumerator_source() {
  local module_dir

  module_dir=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    return 1
  printf '%s\n' "$module_dir/session-enumerator.py"
}

_fwdports_ettun_session_python_file_record() {
  local path=$1 stat_record owner mode device inode size mtime extra uid digest

  [[ $path == /* && $path != *$'\t'* && $path != *$'\r'* &&
    $path != *$'\n'* ]] || {
    printf 'fwdports: ettun macOS session interpreter has an unsafe path\n' \
      >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$path") || {
    printf 'fwdports: cannot identify ettun macOS session interpreter\n' >&2
    return 1
  }
  read -r owner mode device inode size mtime extra <<<"$stat_record"
  uid=$(id -u) || return 1
  if [[ -n $extra || ! $owner =~ ^[0-9]+$ ||
    ! $mode =~ ^[0-7]{3,4}$ || ! $device =~ ^[0-9]+$ ||
    ! $inode =~ ^[0-9]+$ || ! $size =~ ^[0-9]+$ ||
    ! $mtime =~ ^[0-9]+$ || ($owner != 0 && $owner != "$uid") ]] ||
    (((8#$mode & 022) != 0)); then
    printf 'fwdports: ettun macOS session interpreter has untrusted metadata\n' \
      >&2
    return 1
  fi
  digest=$(_fwdports_sha256_file "$path") || {
    printf 'fwdports: cannot hash ettun macOS session interpreter\n' >&2
    return 1
  }
  printf '%s\t%s\n' "$owner:$mode:$device:$inode:$size:$mtime" "$digest"
}

_fwdports_ettun_session_python_resolve() {
  local launcher launcher_record reported current_record path path_record
  local identity digest extra

  if launcher=$(_fwdports_canonical_executable python3 2>/dev/null); then
    :
  elif launcher=$(
    _fwdports_canonical_executable /usr/bin/python3 2>/dev/null
  ); then
    # A runner-managed Python can precede the system binary while living below
    # writable ancestry that is unsuitable for lifecycle authority. The
    # protected system interpreter remains a safe deterministic fallback.
    :
  else
    printf '%s\n' \
      'fwdports: ettun local dependency is not available on macOS: python3' \
      >&2
    return 1
  fi
  launcher_record=$(
    _fwdports_ettun_session_python_file_record "$launcher"
  ) || return 1
  if ! reported=$(
    _fwdports_ettun_session_python_run "$launcher" -c \
      'import os, sys; print(os.path.realpath(sys.executable))'
  ) || [[ $reported != /* || $reported == *$'\t'* ||
    $reported == *$'\r'* || $reported == *$'\n'* ]]; then
    printf '%s\n' \
      'fwdports: ettun macOS session enumerator probe failed (Python 3.9 or newer required)' \
      >&2
    return 1
  fi
  current_record=$(
    _fwdports_ettun_session_python_file_record "$launcher"
  ) || return 1
  [[ $current_record == "$launcher_record" ]] || {
    printf 'fwdports: ettun macOS Python launcher changed during discovery\n' \
      >&2
    return 1
  }
  path=$(_fwdports_canonical_executable "$reported") || {
    printf 'fwdports: ettun macOS Python backend is not trustworthy: %s\n' \
      "$reported" >&2
    return 1
  }
  path_record=$(_fwdports_ettun_session_python_file_record "$path") || return 1
  IFS=$'\t' read -r identity digest extra <<<"$path_record"
  [[ -z $extra && -n $identity && $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\t%s\t%s\n' "$path" "$identity" "$digest"
}

_fwdports_ettun_session_python_run() {
  local python_path=$1
  shift

  (
    # Isolated mode ignores every PYTHON* variable and user site directory.
    # -S also excludes system site customization, while -B prevents cache
    # writes beside the generation-owned helper.
    unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONUSERBASE
    LC_ALL=C "$python_path" -I -S -B "$@"
  )
}

_fwdports_ettun_session_python_probe() {
  local python_path=$1 enumerator=$2

  if ! _fwdports_ettun_session_python_run "$python_path" -c \
    'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' ||
    ! _fwdports_ettun_session_python_run \
      "$python_path" "$enumerator" --probe </dev/null; then
    printf '%s\n' \
      'fwdports: ettun macOS session enumerator probe failed (Python 3.9 or newer required)' \
      >&2
    return 1
  fi
}

fwdports_ettun_validate_local_dependencies() {
  local dependency python_record python_path identity digest extra enumerator

  # These are the non-core commands the public ettun launcher and fwdports'
  # ettun lifecycle boundary need locally. Remote-side relay prerequisites
  # remain the selected VIA host's responsibility.
  for dependency in base64 gzip mkfifo od tee; do
    if ! _fwdports_ettun_command_path "$dependency" >/dev/null; then
      printf 'fwdports: ettun local dependency is not available: %s\n' \
        "$dependency" >&2
      return 1
    fi
  done
  _fwdports_ettun_platform_is_darwin || return 0

  python_record=$(_fwdports_ettun_session_python_resolve) || return 1
  IFS=$'\t' read -r python_path identity digest extra <<<"$python_record"
  [[ -z $extra && -n $python_path && -n $identity &&
    $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  enumerator=$(_fwdports_ettun_session_enumerator_source) || return 1
  [[ -f $enumerator && ! -L $enumerator ]] || {
    printf 'fwdports: ettun macOS session enumerator is unavailable\n' >&2
    return 1
  }
  _fwdports_ettun_session_python_probe "$python_path" "$enumerator" \
    >/dev/null 2>&1 || {
    printf '%s\n' \
      'fwdports: ettun macOS session enumerator probe failed (Python 3.9 or newer required)' \
      >&2
    return 1
  }
}

fwdports_ettun_resolve() {
  local requested=$1 output=$2 path stat_record owner mode device inode size
  local mtime help_text digest old_umask tmp

  path=$(_fwdports_canonical_executable "$requested") || {
    printf 'fwdports: ettun executable is not available: %s\n' \
      "$requested" >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$path") || {
    printf 'fwdports: cannot identify ettun executable\n' >&2
    return 1
  }
  read -r owner mode device inode size mtime <<<"$stat_record"
  if [[ $owner != 0 && $owner != "$(id -u)" ]]; then
    printf 'fwdports: ettun executable has an untrusted owner\n' >&2
    return 1
  fi
  if (((8#$mode & 022) != 0)); then
    printf 'fwdports: ettun executable is group/other writable\n' >&2
    return 1
  fi

  help_text=$(LC_ALL=C "$path" --help 2>&1) || {
    printf 'fwdports: cannot query ettun command contract\n' >&2
    return 1
  }
  [[ $help_text == *'Usage: ettun VIA LOCAL_PORT TARGET TARGET_PORT'* ]] || {
    printf 'fwdports: executable does not provide the expected ettun contract\n' \
      >&2
    return 1
  }
  [[ $help_text == *'Provider contract: remote-port-slot-v1'* ]] || {
    printf '%s\n' \
      'fwdports: executable does not support the remote-port-slot-v1 contract' \
      >&2
    return 1
  }
  fwdports_ettun_validate_local_dependencies || return 1
  digest=$(_fwdports_sha256_file "$path") || {
    printf 'fwdports: cannot hash ettun executable\n' >&2
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
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fwdports_ettun_transport_validate() {
  local path=$1

  if ! (
    unset ETTUN_ET ETTUN_TRANSPORT ETTUN_CLIENT_ID ETTUN_BOOTSTRAP_TIMEOUT \
      ETTUN_REMOTE_PORT_SLOT_V1 ETTUN_TRANSPORT_SINGLE_INVOCATION_V1
    "$path" --fwdports-validate </dev/null >/dev/null
  ); then
    printf 'fwdports: ettun transport adapter dependency validation failed\n' \
      >&2
    return 1
  fi
}

_fwdports_ettun_transport_query_capabilities() {
  local path=$1 output_path=$2 output line prior count=0 query_status=0
  local -a capabilities=()

  # Capability discovery must not consume the caller's terminal. A legacy
  # adapter which does not implement the query remains a valid local-only
  # transport and is represented by an empty capability record.
  output=$(
    unset ETTUN_ET ETTUN_TRANSPORT ETTUN_CLIENT_ID ETTUN_BOOTSTRAP_TIMEOUT \
      ETTUN_REMOTE_PORT_SLOT_V1 ETTUN_TRANSPORT_SINGLE_INVOCATION_V1
    "$path" --ettun-capabilities </dev/null 2>/dev/null
  ) || query_status=$?
  ((${#output} <= 4096)) || {
    printf 'fwdports: ettun transport adapter capability output is invalid\n' \
      >&2
    return 1
  }
  ((query_status == 0)) || output=
  if [[ -n $output ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[a-z][a-z0-9-]{0,63}$ ]] || {
        printf 'fwdports: ettun transport adapter capability output is invalid\n' \
          >&2
        return 1
      }
      count=$((count + 1))
      ((count <= 32)) || {
        printf 'fwdports: ettun transport adapter capability output is invalid\n' \
          >&2
        return 1
      }
      for prior in "${capabilities[@]+"${capabilities[@]}"}"; do
        [[ $prior != "$line" ]] || {
          printf 'fwdports: ettun transport adapter capability output is invalid\n' \
            >&2
          return 1
        }
      done
      capabilities+=("$line")
    done <<<"$output"
  fi
  if ((count == 0)); then
    _fwdports_write_private_lines "$output_path"
  else
    _fwdports_write_private_lines "$output_path" "${capabilities[@]}"
  fi
}

_fwdports_ettun_capability_file_has() {
  local capability_file=$1 requested=$2 line

  [[ -f $capability_file && ! -L $capability_file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line != "$requested" ]] || return 0
  done <"$capability_file"
  return 1
}

_fwdports_ettun_capability_files_equal() {
  local left=$1 right=$2

  [[ -f $left && ! -L $left && -f $right && ! -L $right ]] || return 1
  [[ $(<"$left") == "$(<"$right")" ]]
}

_fwdports_ettun_argv_requires_connect_v2() {
  local argv_file=$1 element

  [[ -f $argv_file && ! -L $argv_file ]] || return 1
  while IFS= read -r element || [[ -n $element ]]; do
    [[ $element != --reverse ]] || return 0
  done <"$argv_file"
  return 1
}

fwdports_ettun_transport_resolve() {
  local requested=$1 output=$2 required_capability=${3:-}
  local capabilities_output=${4:-} capability_record path stat_record
  local owner mode device inode size mtime digest old_umask tmp

  [[ -z $required_capability ||
    $required_capability =~ ^[a-z][a-z0-9-]{0,63}$ ]] || return 1
  [[ -z $capabilities_output || $capabilities_output != "$output" ]] ||
    return 1
  rm -f -- "$output" || return 1
  [[ -z $capabilities_output ]] ||
    rm -f -- "$capabilities_output" || return 1

  path=$(_fwdports_canonical_executable "$requested") || {
    printf 'fwdports: ettun transport adapter is not available: %s\n' \
      "$requested" >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$path") || {
    printf 'fwdports: cannot identify ettun transport adapter\n' >&2
    return 1
  }
  read -r owner mode device inode size mtime <<<"$stat_record"
  if [[ $owner != 0 && $owner != "$(id -u)" ]] ||
    (((8#$mode & 022) != 0)); then
    printf 'fwdports: ettun transport adapter has untrusted metadata\n' >&2
    return 1
  fi
  _fwdports_ettun_transport_validate "$path" || return 1
  capability_record=${capabilities_output:-${output}.capabilities}
  _fwdports_ettun_transport_query_capabilities "$path" \
    "$capability_record" || {
    rm -f -- "$output" "$capability_record"
    return 1
  }
  if [[ -n $required_capability ]] &&
    ! _fwdports_ettun_capability_file_has "$capability_record" \
      "$required_capability"; then
    printf 'fwdports: ettun transport adapter required capability is unavailable: %s\n' \
      "$required_capability" >&2
    rm -f -- "$output" "$capability_record"
    return 1
  fi
  digest=$(_fwdports_sha256_file "$path") || {
    printf 'fwdports: cannot hash ettun transport adapter\n' >&2
    rm -f -- "$capability_record"
    return 1
  }

  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "${output}.tmp.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$capability_record"
    return 1
  }
  umask "$old_umask"
  if ! {
    printf 'path\t%s\n' "$path"
    printf 'identity\t%s:%s:%s:%s:%s\n' \
      "$device" "$inode" "$mode" "$size" "$mtime"
    printf 'digest\t%s\n' "$digest"
  } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    rm -f -- "$capability_record"
    return 1
  fi
  [[ -n $capabilities_output ]] || rm -f -- "$capability_record"
}

fwdports_ettun_snapshot_executable() {
  local source_record=$1 destination=$2 description=$3 line key value extra
  local path='' expected_identity='' expected_digest='' line_number=0
  local stat_record owner mode device inode size mtime identity digest
  local destination_parent old_umask tmp snapshot_digest

  [[ -f $source_record && ! -L $source_record ]] || {
    printf 'fwdports: %s source record is unavailable\n' "$description" >&2
    return 1
  }
  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    IFS=$'\t' read -r key value extra <<<"$line"
    [[ -n $value && -z $extra ]] || return 1
    case "$line_number:$key" in
      1:path) path=$value ;;
      2:identity) expected_identity=$value ;;
      3:digest) expected_digest=$value ;;
      *) return 1 ;;
    esac
  done <"$source_record"
  [[ $line_number -eq 3 && $path == /* && -f $path && -x $path &&
    ! -L $path && $expected_identity =~ ^[^:]+:[^:]+:[0-7]+:[^:]+:[^:]+$ &&
    $expected_digest =~ ^[0-9a-f]{64}$ ]] || {
    printf 'fwdports: %s source record is invalid\n' "$description" >&2
    return 1
  }

  stat_record=$(_fwdports_stat_identity "$path") || return 1
  read -r owner mode device inode size mtime <<<"$stat_record"
  identity=$device:$inode:$mode:$size:$mtime
  if [[ $owner != 0 && $owner != "$(id -u)" ]] ||
    (((8#$mode & 022) != 0)) || [[ $identity != "$expected_identity" ]]; then
    printf 'fwdports: %s changed before snapshot\n' "$description" >&2
    return 1
  fi
  digest=$(_fwdports_sha256_file "$path") || return 1
  [[ $digest == "$expected_digest" ]] || {
    printf 'fwdports: %s changed before snapshot\n' "$description" >&2
    return 1
  }

  destination_parent=${destination%/*}
  [[ $destination_parent != "$destination" && -d $destination_parent &&
    ! -L $destination_parent && ! -e $destination && ! -L $destination ]] || {
    printf 'fwdports: %s snapshot destination is unavailable\n' \
      "$description" >&2
    return 1
  }
  stat_record=$(_fwdports_stat_identity "$destination_parent") || return 1
  read -r owner mode device inode size mtime <<<"$stat_record"
  if [[ $owner != 0 && $owner != "$(id -u)" ]] ||
    (((8#$mode & 022) != 0)); then
    printf 'fwdports: %s snapshot parent is untrusted\n' \
      "$description" >&2
    return 1
  fi
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$destination_parent/.ettun-snapshot.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! cp -- "$path" "$tmp" || ! chmod 0700 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  snapshot_digest=$(_fwdports_sha256_file "$tmp") || {
    rm -f -- "$tmp"
    return 1
  }

  stat_record=$(_fwdports_stat_identity "$path") || {
    rm -f -- "$tmp"
    return 1
  }
  read -r owner mode device inode size mtime <<<"$stat_record"
  identity=$device:$inode:$mode:$size:$mtime
  digest=$(_fwdports_sha256_file "$path") || {
    rm -f -- "$tmp"
    return 1
  }
  if [[ ! -f $path || ! -x $path || -L $path ||
    ($owner != 0 && $owner != "$(id -u)") ]] ||
    (((8#$mode & 022) != 0)) || [[ $identity != "$expected_identity" ||
    $digest != "$expected_digest" ||
    $snapshot_digest != "$expected_digest" ]]; then
    rm -f -- "$tmp"
    printf 'fwdports: %s changed while being snapshotted\n' \
      "$description" >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$destination"; then
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
  if [[ $version_text =~ ^et[[:space:]]+version[[:space:]]+(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([+]([0-9A-Za-z-]+([.][0-9A-Za-z-]+)*))?$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
    version=$major.$minor.$patch${BASH_REMATCH[4]:-}
  else
    printf 'fwdports: unrecognized Eternal Terminal version output\n' >&2
    return 1
  fi
  # ET 7.0.0 established the command surface and PATH-based SSH bootstrap
  # contract used below. Treat stable newer releases as backward compatible,
  # while retaining the capability, executable identity, and digest gates.
  case "$major" in
    0 | 1 | 2 | 3 | 4 | 5 | 6)
      printf 'fwdports: ET 7.0.0 or newer is required (found %s)\n' \
        "$version" >&2
      return 1
      ;;
  esac
  help_text=$(LC_ALL=C "$path" --help 2>&1) || {
    printf 'fwdports: cannot query Eternal Terminal capabilities\n' >&2
    return 1
  }
  for capability in --port --tunnel --reversetunnel --jumphost --logdir \
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

_fwdports_ettun_prepare_session_enumerator() {
  local runtime=$1 source python_record python_path identity python_digest
  local extra current_record helper_record helper_owner helper_mode
  local helper_device helper_inode helper_size helper_mtime helper_extra
  local helper_identity helper_digest old_umask helper_tmp python_tmp

  _fwdports_ettun_platform_is_darwin || return 0
  source=$(_fwdports_ettun_session_enumerator_source) || return 1
  python_record=$(_fwdports_ettun_session_python_resolve) || return 1
  IFS=$'\t' read -r python_path identity python_digest extra \
    <<<"$python_record"
  [[ -z $extra && -n $python_path && -n $identity &&
    $python_digest =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ -f $source && ! -L $source ]] || {
    printf 'fwdports: ettun macOS session enumerator is unavailable\n' >&2
    return 1
  }

  old_umask=$(umask)
  umask 077
  helper_tmp=$(mktemp "$runtime/.session-enumerator.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  python_tmp=$(mktemp "$runtime/.session-python.XXXXXXXX") || {
    umask "$old_umask"
    rm -f -- "$helper_tmp"
    return 1
  }
  umask "$old_umask"
  if ! cp -- "$source" "$helper_tmp" || ! chmod 0600 "$helper_tmp" ||
    ! _fwdports_ettun_session_python_probe \
      "$python_path" "$helper_tmp" </dev/null >/dev/null 2>&1; then
    printf '%s\n' \
      'fwdports: ettun macOS session enumerator probe failed (Python 3.9 or newer required)' \
      >&2
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  fi
  helper_digest=$(_fwdports_sha256_file "$helper_tmp") || {
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  }
  helper_record=$(_fwdports_stat_identity "$helper_tmp") || {
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  }
  read -r helper_owner helper_mode helper_device helper_inode helper_size \
    helper_mtime helper_extra <<<"$helper_record"
  [[ -z $helper_extra && $helper_owner =~ ^[0-9]+$ &&
    $helper_mode =~ ^[0-7]{3,4}$ && $helper_device =~ ^[0-9]+$ &&
    $helper_inode =~ ^[0-9]+$ && $helper_size =~ ^[0-9]+$ &&
    $helper_mtime =~ ^[0-9]+$ ]] || {
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  }
  helper_identity=$helper_owner:$helper_mode:$helper_device:$helper_inode
  helper_identity=$helper_identity:$helper_size:$helper_mtime
  current_record=$(_fwdports_ettun_session_python_resolve) || {
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  }
  [[ $current_record == "$python_record" ]] || {
    printf 'fwdports: ettun macOS session interpreter changed during prepare\n' \
      >&2
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  }
  if ! printf '%s\n' \
    $'path\t'"$python_path" \
    $'identity\t'"$identity" \
    $'digest\t'"$python_digest" \
    $'helper-identity\t'"$helper_identity" \
    $'helper-digest\t'"$helper_digest" >"$python_tmp" ||
    ! chmod 0600 "$python_tmp"; then
    rm -f -- "$helper_tmp" "$python_tmp"
    return 1
  fi
  if ! mv -f -- "$helper_tmp" "$runtime/session-enumerator.py" ||
    ! mv -f -- "$python_tmp" "$runtime/session-python"; then
    rm -f -- "$helper_tmp" "$python_tmp" \
      "$runtime/session-enumerator.py" "$runtime/session-python"
    return 1
  fi
}

fwdports_ettun_prepare_runtime() {
  local runtime=$1 stock_et=${2:-0} module_dir gate_template
  local et_gate_template shim_template gate_tmp et_gate_tmp='' shim_tmp=''
  local temp_dir=$runtime/ettun-tmp et_bin_dir=$runtime/et-bin
  local et_temp_dir=$runtime/et-tmp old_umask

  module_dir=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    return 1
  gate_template=$module_dir/ettun-gate.sh
  et_gate_template=$module_dir/ettun-et-gate.sh
  shim_template=$module_dir/et-ssh-wrapper.sh
  [[ $stock_et == 0 || $stock_et == 1 ]] || return 1
  [[ -f $gate_template && -x $gate_template &&
    ! -L $gate_template ]] || {
    printf 'fwdports: ettun gate template is unavailable\n' >&2
    return 1
  }
  if [[ $stock_et -eq 1 ]] &&
    ! [[ -f $et_gate_template && -x $et_gate_template &&
      ! -L $et_gate_template && -f $shim_template && -x $shim_template &&
      ! -L $shim_template ]]; then
    printf 'fwdports: ettun stock ET gate templates are unavailable\n' >&2
    return 1
  fi

  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$temp_dir" || ! chmod 0700 "$temp_dir"; then
    umask "$old_umask"
    return 1
  fi
  if [[ $stock_et -eq 1 ]] &&
    { ! mkdir -p "$et_bin_dir" "$et_temp_dir" ||
      ! chmod 0700 "$et_bin_dir" "$et_temp_dir"; }; then
    umask "$old_umask"
    return 1
  fi
  gate_tmp=$(mktemp "$runtime/.ettun-gate.XXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  if [[ $stock_et -eq 1 ]]; then
    et_gate_tmp=$(mktemp "$runtime/.ettun-et-gate.XXXXXXXX") || {
      umask "$old_umask"
      rm -f -- "$gate_tmp"
      return 1
    }
    shim_tmp=$(mktemp "$et_bin_dir/.ssh.XXXXXXXX") || {
      umask "$old_umask"
      rm -f -- "$gate_tmp" "$et_gate_tmp"
      return 1
    }
  fi
  umask "$old_umask"
  if ! cp -- "$gate_template" "$gate_tmp" || ! chmod 0700 "$gate_tmp"; then
    rm -f -- "$gate_tmp" "$et_gate_tmp" "$shim_tmp"
    return 1
  fi
  if [[ $stock_et -eq 1 ]]; then
    if ! cp -- "$et_gate_template" "$et_gate_tmp" ||
      ! cp -- "$shim_template" "$shim_tmp" ||
      ! chmod 0700 "$et_gate_tmp" "$shim_tmp" ||
      ! mv -f -- "$shim_tmp" "$et_bin_dir/ssh" ||
      ! mv -f -- "$et_gate_tmp" "$runtime/ettun-et-gate"; then
      rm -f -- "$gate_tmp" "$et_gate_tmp" "$shim_tmp" \
        "$et_bin_dir/ssh" "$runtime/ettun-et-gate"
      return 1
    fi
  fi
  # The outer gate is the complete-runtime marker and is published last.
  if ! mv -f -- "$gate_tmp" "$runtime/ettun-gate"; then
    rm -f -- "$gate_tmp" "$runtime/ettun-gate" "$runtime/ettun-et-gate" \
      "$et_bin_dir/ssh"
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

_fwdports_prepare_et_ssh_gates() {
  local runtime=$1 target=$2 ssh_path
  local ssh_source=$runtime/et-ssh-source
  local ambient_argv=$runtime/et-ssh-ambient-argv
  local ambient_digest=$runtime/et-ssh-ambient-digest
  local bootstrap_argv=$runtime/et-ssh-argv
  local bootstrap_digest=$runtime/et-ssh-bootstrap-digest
  local proxyjump_plan=$runtime/et-ssh-proxyjump
  local jump_ambient_argv=$runtime/et-ssh-jump-ambient-argv
  local jump_ambient_digest=$runtime/et-ssh-jump-ambient-digest
  local jump_bootstrap_argv=$runtime/et-ssh-jump-argv
  local jump_bootstrap_digest=$runtime/et-ssh-jump-bootstrap-digest
  local kind value plan_target='' destination_endpoint=''
  local jump_selector='' jump_endpoint='' plan_records=0
  local -a bootstrap_options=()

  # Both direct ET and stock-ET-backed ettun invoke an ambient command named
  # `ssh`. Publish the same trusted executable plus ambient and hardened
  # bootstrap gates for either outer driver. Their ET engine gates remain
  # separate because those have different argv and lifecycle contracts.
  fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" "$ssh_source" ||
    return 1
  ssh_path=$(LC_ALL=C sed -n 's/^path\t//p' "$ssh_source") || return 1
  [[ -n $ssh_path ]] || return 1

  _fwdports_write_private_lines "$ambient_argv" || return 1
  fwdports_et_write_ssh_argv "$bootstrap_argv" || return 1
  _fwdports_et_proxyjump_plan "$ssh_path" "$target" "$proxyjump_plan" ||
    return 1

  if [[ ! -s $proxyjump_plan ]]; then
    fwdports_ssh_effective_digest "$ssh_path" "$target" "$ambient_argv" \
      "$ambient_digest" et || return 1
    fwdports_ssh_prepare_gate "$runtime/et-ssh-ambient" "$ssh_source" \
      "$ambient_digest" || return 1
    fwdports_ssh_effective_digest "$ssh_path" "$target" "$bootstrap_argv" \
      "$bootstrap_digest" || return 1
    fwdports_ssh_prepare_gate "$runtime/et-ssh-bootstrap" "$ssh_source" \
      "$bootstrap_digest"
    return
  fi

  while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
    plan_records=$((plan_records + 1))
    case "$kind" in
      target) plan_target=$value ;;
      destination) destination_endpoint=$value ;;
      jump-selector) jump_selector=$value ;;
      jump-endpoint) jump_endpoint=$value ;;
      *) return 1 ;;
    esac
  done <"$proxyjump_plan"
  [[ $plan_records -eq 4 && $plan_target == "$target" &&
    -n $destination_endpoint && -n $jump_selector && -n $jump_endpoint ]] ||
    return 1

  fwdports_ssh_effective_digest "$ssh_path" "$target" "$ambient_argv" \
    "$ambient_digest" et-proxy || return 1
  fwdports_ssh_prepare_gate "$runtime/et-ssh-ambient" "$ssh_source" \
    "$ambient_digest" || return 1
  _fwdports_write_private_lines "$jump_ambient_argv" || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$jump_selector" \
    "$jump_ambient_argv" "$jump_ambient_digest" et || return 1
  fwdports_ssh_prepare_gate "$runtime/et-ssh-jump-ambient" "$ssh_source" \
    "$jump_ambient_digest" || return 1

  while IFS= read -r value || [[ -n $value ]]; do
    [[ -n $value && $value != *$'\t'* && $value != *$'\r'* ]] || return 1
    bootstrap_options+=("$value")
  done <"$bootstrap_argv"
  [[ -n ${bootstrap_options[0]+set} ]] || return 1
  _fwdports_write_private_lines "$runtime/et-ssh-target-argv" \
    "${bootstrap_options[@]}" -J "$jump_endpoint" || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$destination_endpoint" \
    "$runtime/et-ssh-target-argv" "$bootstrap_digest" et-proxy || return 1
  fwdports_ssh_prepare_gate "$runtime/et-ssh-bootstrap" "$ssh_source" \
    "$bootstrap_digest" || return 1

  _fwdports_write_private_lines "$jump_bootstrap_argv" \
    "${bootstrap_options[@]}" || return 1
  fwdports_ssh_effective_digest "$ssh_path" "$jump_endpoint" \
    "$jump_bootstrap_argv" "$jump_bootstrap_digest" et || return 1
  fwdports_ssh_prepare_gate "$runtime/et-ssh-jump-bootstrap" "$ssh_source" \
    "$jump_bootstrap_digest"
}

_fwdports_builtin_prepare_et() {
  local manifest=$1 leg=$2 runtime=$3 target_override=$4
  local et_source=$runtime/et-source et_argv=$runtime/et-argv
  local et_target=$runtime/et-target et_log=$runtime/et-log

  fwdports_et_resolve "${FWDPORTS_ET_COMMAND:-et}" "$et_source" || return 1
  fwdports_et_build_argv "$manifest" "$leg" "$target_override" \
    "$et_argv" "$et_target" "$et_log" || return 1
  fwdports_et_preflight_local_ports "$manifest" "$leg" || return 1

  _fwdports_prepare_et_ssh_gates "$runtime" "$(<"$et_target")" ||
    return 1
  fwdports_et_prepare_runtime "$runtime"
}

_fwdports_ettun_default_et_via() {
  local argv_file=$1 via

  [[ -f $argv_file && ! -L $argv_file ]] || return 1
  via=$(LC_ALL=C sed -n '1p' "$argv_file") || return 1
  _fwdports_et_safe_target "$via" || {
    printf '%s\n' \
      'fwdports: ettun default ET host is unsupported; select a validated transport adapter' \
      >&2
    return 1
  }
  printf '%s\n' "$via"
}

_fwdports_ettun_prepare_stock_et() {
  local runtime=$1 via

  via=$(_fwdports_ettun_default_et_via "$runtime/ettun-argv") || return 1
  _fwdports_write_private_lines "$runtime/et-target" "$via" || return 1
  _fwdports_prepare_et_ssh_gates "$runtime" "$via"
}

_fwdports_builtin_prepare_ettun() {
  local manifest=$1 leg=$2 runtime=$3 target_override=$4 transport
  local stock_et=0 required_capability='' snapshot_capabilities

  fwdports_ettun_resolve "${FWDPORTS_ETTUN_COMMAND:-ettun}" \
    "$runtime/ettun-source" || return 1
  fwdports_ettun_build_argv "$manifest" "$leg" "$target_override" \
    "$runtime/ettun-argv" "$runtime/ettun-transport" || return 1
  _fwdports_ettun_assign_remote_port_slot "$manifest" "$leg" \
    "$runtime/ettun-remote-port-slot-v1" || return 1
  if _fwdports_ettun_argv_requires_connect_v2 "$runtime/ettun-argv"; then
    required_capability=connect-v2
  fi
  transport=$(<"$runtime/ettun-transport") || return 1
  if [[ -n $transport ]]; then
    fwdports_ettun_transport_resolve "$transport" \
      "$runtime/ettun-transport-source" "$required_capability" \
      "$runtime/ettun-transport-capabilities" || return 1
  else
    stock_et=1
    # The public ettun command uses ET unless a manifest-selected adapter owns
    # its nested dependencies. Resolve the selected path before any tmux
    # session or earlier leg can start.
    fwdports_et_resolve "${FWDPORTS_ETTUN_ET_COMMAND:-et}" \
      "$runtime/ettun-et-source" || return 1
    _fwdports_ettun_prepare_stock_et "$runtime" || return 1
  fi
  fwdports_et_preflight_local_ports "$manifest" "$leg" || return 1
  fwdports_ettun_snapshot_executable "$runtime/ettun-source" \
    "$runtime/ettun-engine" 'ettun executable' || return 1
  if [[ -n $transport ]]; then
    fwdports_ettun_snapshot_executable "$runtime/ettun-transport-source" \
      "$runtime/ettun-transport-exec" 'ettun transport adapter' || return 1
    # The capability and dependency probes happened before the mutable source
    # was hashed. Repeat both against the immutable generation snapshot so a
    # source replacement during preparation cannot change the selected
    # contract after validation.
    _fwdports_ettun_transport_validate \
      "$runtime/ettun-transport-exec" || return 1
    snapshot_capabilities=$runtime/ettun-transport-snapshot-capabilities
    _fwdports_ettun_transport_query_capabilities \
      "$runtime/ettun-transport-exec" "$snapshot_capabilities" || return 1
    if ! _fwdports_ettun_capability_files_equal \
      "$runtime/ettun-transport-capabilities" "$snapshot_capabilities"; then
      printf '%s\n' \
        'fwdports: ettun transport adapter capabilities changed during snapshot' \
        >&2
      return 1
    fi
  fi
  _fwdports_ettun_prepare_session_enumerator "$runtime" || return 1
  fwdports_ettun_prepare_runtime "$runtime" "$stock_et"
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

fwdports_builtin_preflight_dependencies() {
  local manifest=$1 preflight_root=$2 target_override=${3:-}
  local kind leg driver _ runtime transport via index required_capability
  local -a legs=() drivers=()

  [[ -f $manifest && ! -L $manifest ]] || {
    printf 'fwdports: resolved profile is unavailable for dependency preflight\n' \
      >&2
    return 1
  }
  [[ $preflight_root == /* ]] || return 1
  mkdir -p "$preflight_root" || return 1
  [[ -d $preflight_root && ! -L $preflight_root ]] || return 1
  chmod 0700 "$preflight_root" || return 1

  while IFS=$'\t' read -r kind leg driver _ || [[ -n ${kind:-} ]]; do
    [[ $kind == leg ]] || continue
    fwdports_driver_is_builtin "$driver" || continue
    legs+=("$leg")
    drivers+=("$driver")
  done <"$manifest"
  # Bash 3.2 treats the length of an empty nounset array as an unbound
  # expansion. An external-driver-only profile has nothing to preflight here.
  [[ -n ${legs[0]+set} ]] || return 0

  for ((index = 0; index < ${#legs[@]}; index++)); do
    leg=${legs[index]}
    driver=${drivers[index]}
    runtime=$preflight_root/$leg
    mkdir "$runtime" || return 1
    chmod 0700 "$runtime" || return 1

    # This phase deliberately resolves only executable dependencies. Local
    # bind checks remain in generation preparation because the active
    # generation may legitimately own the replacement's desired port until
    # cutover. Generation preparation repeats these checks and pins the exact
    # executable identities used at launch.
    case "$driver" in
      ssh)
        fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" \
          "$runtime/ssh-source" || return 1
        ;;
      autossh)
        fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" \
          "$runtime/ssh-source" || return 1
        fwdports_autossh_resolve "${FWDPORTS_AUTOSSH_COMMAND:-autossh}" \
          "$runtime/autossh-source" || return 1
        ;;
      et)
        fwdports_et_resolve "${FWDPORTS_ET_COMMAND:-et}" \
          "$runtime/et-source" || return 1
        fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" \
          "$runtime/ssh-source" || return 1
        ;;
      ettun)
        fwdports_ettun_resolve "${FWDPORTS_ETTUN_COMMAND:-ettun}" \
          "$runtime/ettun-source" || return 1
        fwdports_ettun_build_argv "$manifest" "$leg" "$target_override" \
          "$runtime/ettun-argv" "$runtime/ettun-transport" || return 1
        required_capability=
        if _fwdports_ettun_argv_requires_connect_v2 \
          "$runtime/ettun-argv"; then
          required_capability=connect-v2
        fi
        transport=$(<"$runtime/ettun-transport") || return 1
        if [[ -n $transport ]]; then
          fwdports_ettun_transport_resolve "$transport" \
            "$runtime/ettun-transport-source" "$required_capability" \
            "$runtime/ettun-transport-capabilities" || return 1
        else
          via=$(_fwdports_ettun_default_et_via "$runtime/ettun-argv") ||
            return 1
          fwdports_et_resolve "${FWDPORTS_ETTUN_ET_COMMAND:-et}" \
            "$runtime/ettun-et-source" || return 1
          fwdports_ssh_resolve "${FWDPORTS_SSH_COMMAND:-ssh}" \
            "$runtime/ssh-source" || return 1
        fi
        ;;
      *)
        printf 'fwdports: unsupported built-in dependency preflight: %s\n' \
          "$driver" >&2
        return 1
        ;;
    esac
  done
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
    ettun)
      _fwdports_builtin_prepare_ettun "$manifest" "$leg" "$runtime" \
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

fwdports_builtin_interactive_prepare() {
  local manifest=$1 leg=$2 driver=$3 runtime=$4
  local capability_file=$runtime/ettun-transport-capabilities
  local adapter=$runtime/ettun-transport-exec

  fwdports_driver_is_builtin "$driver" || return 1
  [[ -f $manifest && ! -L $manifest && -d $runtime && ! -L $runtime ]] ||
    return 1
  [[ $driver == ettun ]] || return 0

  # Stock ET and legacy local-only adapters have no foreground preparation
  # operation. Only a capability authenticated before snapshotting grants the
  # immutable adapter permission to interact with the user's terminal here.
  _fwdports_ettun_capability_file_has "$capability_file" \
    fwdports-prepare-v1 || return 0
  [[ -f $adapter && -x $adapter && ! -L $adapter ]] || {
    printf 'fwdports: prepared ettun transport adapter is unavailable\n' >&2
    return 1
  }
  (
    unset ETTUN_ET ETTUN_TRANSPORT ETTUN_CLIENT_ID ETTUN_BOOTSTRAP_TIMEOUT \
      ETTUN_REMOTE_PORT_SLOT_V1 ETTUN_TRANSPORT_SINGLE_INVOCATION_V1
    "$adapter" --fwdports-prepare-v1 "$manifest" "$leg" "$runtime"
  )
}
