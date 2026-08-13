#!/usr/bin/env bash
# Small, deterministic health policy helpers.  They deliberately use elapsed
# controller ticks rather than wall-clock timestamps so a clock correction can
# neither skip a retry nor stretch a backoff indefinitely.

fwdports_backoff_for_failures() {
  local failures=$1 value=1 index=0
  [[ $failures =~ ^[0-9]+$ ]] || return 1
  while [[ $index -lt $failures && $value -lt 30 ]]; do
    value=$((value * 2))
    [[ $value -le 30 ]] || value=30
    index=$((index + 1))
  done
  printf '%s\n' "$value"
}

fwdports_health_probe_local_tcp() {
  local host=$1 port=$2 nc_path

  [[ -n $host && $port =~ ^[0-9]+$ ]] || return 64
  nc_path=$(type -P -- nc 2>/dev/null) || {
    printf 'unavailable (nc not installed)\n'
    return 2
  }
  # OpenBSD nc on macOS and common Linux nc variants all accept this narrow
  # connect-only form. No payload is sent, and the timeout bounds each
  # point-in-time observation independently.
  if "$nc_path" -z -w 5 "$host" "$port" >/dev/null 2>&1; then
    printf 'passing\n'
    return 0
  fi
  printf 'failing\n'
  return 1
}

fwdports_health_probe() {
  local manifest=$1 kind leg probe_type host port label extra found=0
  local failed=0

  [[ -f $manifest && ! -L $manifest ]] || return 1
  while IFS=$'\t' read -r kind leg probe_type host port label extra ||
    [[ -n ${kind:-} ]]; do
    [[ $kind == check ]] || continue
    found=1
    [[ -z $extra && $port =~ ^[0-9]+$ ]] || {
      failed=1
      continue
    }
    case "$probe_type" in
      loopback | tcp) ;;
      *)
        failed=1
        continue
        ;;
    esac
    fwdports_health_probe_local_tcp "$host" "$port" >/dev/null || failed=1
    : "$leg" "$label"
  done <"$manifest"
  if [[ $found -eq 0 ]]; then
    printf 'none\n'
    return 2
  fi
  if [[ $failed -eq 1 ]]; then
    printf 'failing\n'
    return 1
  fi
  printf 'passing\n'
}
