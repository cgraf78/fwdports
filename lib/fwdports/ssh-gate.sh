#!/usr/bin/env bash
# Generation-owned SSH launch gate. Core snapshots this file beside the exact
# executable identity and effective-config digest selected at start. Every
# retry rechecks both before exec, preventing an unattended reconnect from
# silently adopting changed routing or authentication configuration.

set -u
umask 077

GATE_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 70
IDENTITY_FILE=$GATE_DIR/ssh-identity
DIGEST_FILE=$GATE_DIR/ssh-digest
DRIFT_FILE=$GATE_DIR/ssh-drift

gate_stat_identity() {
  local path=$1 output _owner mode device inode size mtime

  if output=$(LC_ALL=C stat -c '%u %a %d %i %s %Y' -- "$path" 2>/dev/null) ||
    output=$(LC_ALL=C stat -f '%u %Lp %d %i %z %m' "$path" 2>/dev/null); then
    read -r _owner mode device inode size mtime <<<"$output"
    printf '%s:%s:%s:%s:%s\n' "$device" "$inode" "$mode" "$size" "$mtime"
    return 0
  fi
  return 1
}

gate_sha256() {
  local path=$1 output
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$path") || return 1
    printf '%s\n' "${output%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$path") || return 1
    printf '%s\n' "${output%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    output=$(openssl dgst -sha256 "$path") || return 1
    output=${output##*= }
    [[ $output =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s\n' "$output" | LC_ALL=C tr 'A-F' 'a-f'
  else
    return 1
  fi
}

publish_drift() {
  local class=$1 tmp
  tmp=$(mktemp "$GATE_DIR/.ssh-drift.XXXXXXXX") || exit 78
  if ! printf '%s\n' "$class" >"$tmp" || ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$DRIFT_FILE"; then
    rm -f -- "$tmp"
  fi
  exit 78
}

check_only=0
if [[ ${1:-} == --check-only ]]; then
  check_only=1
  shift
fi
[[ $# -gt 0 ]] || exit 64

ssh_path=
expected_identity=
while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
  case "$kind" in
    path) ssh_path=$value ;;
    identity) expected_identity=$value ;;
  esac
done <"$IDENTITY_FILE"
expected_digest=$(<"$DIGEST_FILE")

if [[ -z $ssh_path || -z $expected_identity ||
  ! $expected_digest =~ ^[0-9a-f]{64}$ ||
  ! -f $ssh_path || ! -x $ssh_path ]]; then
  publish_drift ssh-binary-drift
fi
actual_identity=$(gate_stat_identity "$ssh_path") ||
  publish_drift ssh-binary-drift
[[ $actual_identity == "$expected_identity" ]] ||
  publish_drift ssh-binary-drift

raw=$(mktemp "$GATE_DIR/.ssh-config.XXXXXXXX") || exit 78
normalized=$(mktemp "$GATE_DIR/.ssh-normalized.XXXXXXXX") || {
  rm -f -- "$raw"
  exit 78
}
if ! LC_ALL=C "$ssh_path" -G "$@" >"$raw" 2>/dev/null ||
  ! LC_ALL=C sed -e 's/\r$//' -e 's/[[:space:]]*$//' \
    "$raw" >"$normalized"; then
  rm -f -- "$raw" "$normalized"
  publish_drift ssh-config-drift
fi
actual_digest=$(gate_sha256 "$normalized") || {
  rm -f -- "$raw" "$normalized"
  publish_drift ssh-config-drift
}
rm -f -- "$raw" "$normalized"
[[ $actual_digest == "$expected_digest" ]] ||
  publish_drift ssh-config-drift

rm -f -- "$DRIFT_FILE"
if [[ $check_only -eq 1 ]]; then
  exit 0
fi
exec "$ssh_path" "$@"
