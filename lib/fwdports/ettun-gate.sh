#!/usr/bin/env bash
# Generation-owned ettun launch gate. Both the relay engine and its selected
# transport are authenticated immediately before the foreground exec so a
# reconnecting generation cannot silently adopt replacement bytes.

set -u
umask 077

GATE_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 70
DRIFT_FILE=$GATE_DIR/ettun-drift

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

  tmp=$(mktemp "$GATE_DIR/.ettun-drift.XXXXXXXX") || exit 78
  if ! printf '%s\n' "$class" >"$tmp" || ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$DRIFT_FILE"; then
    rm -f -- "$tmp"
  fi
  exit 78
}

read_source() {
  local source=$1 class=$2 kind value
  local path='' expected_identity='' expected_digest=''

  [[ -f $source && ! -L $source ]] || publish_drift "$class"
  while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
    case "$kind" in
      path) path=$value ;;
      identity) expected_identity=$value ;;
      digest) expected_digest=$value ;;
    esac
  done <"$source"
  [[ -n $path && -n $expected_identity &&
    $expected_digest =~ ^[0-9a-f]{64}$ && -f $path && -x $path ]] ||
    publish_drift "$class"
  [[ $(gate_stat_identity "$path") == "$expected_identity" ]] ||
    publish_drift "$class"
  [[ $(gate_sha256 "$path") == "$expected_digest" ]] ||
    publish_drift "$class"
  printf '%s\t%s\n' "$path" "$expected_digest"
}

ettun_record=$(read_source "$GATE_DIR/ettun-source" ettun-binary-drift) ||
  exit $?
IFS=$'\t' read -r _ettun_source ettun_digest extra <<<"$ettun_record"
[[ -z ${extra:-} && -n $_ettun_source &&
  -f $GATE_DIR/ettun-engine && -x $GATE_DIR/ettun-engine &&
  ! -L $GATE_DIR/ettun-engine &&
  $(gate_sha256 "$GATE_DIR/ettun-engine") == "$ettun_digest" ]] ||
  publish_drift ettun-generation-drift
ettun_path=$GATE_DIR/ettun-engine

transport_name=''
transport_records=0
[[ -f $GATE_DIR/ettun-transport && ! -L $GATE_DIR/ettun-transport ]] ||
  publish_drift ettun-generation-drift
while IFS= read -r element || [[ -n $element ]]; do
  transport_records=$((transport_records + 1))
  [[ $transport_records -eq 1 && -n $element && $element != *$'\t'* &&
    $element != *$'\r'* ]] || publish_drift ettun-generation-drift
  transport_name=$element
done <"$GATE_DIR/ettun-transport"

if [[ -n $transport_name ]]; then
  [[ ! -e $GATE_DIR/ettun-et-source ]] ||
    publish_drift ettun-generation-drift
  transport_record=$(read_source "$GATE_DIR/ettun-transport-source" \
    ettun-transport-binary-drift) || exit $?
  IFS=$'\t' read -r _transport_source transport_digest extra \
    <<<"$transport_record"
  [[ -z ${extra:-} && -n $_transport_source &&
    -f $GATE_DIR/ettun-transport-exec &&
    -x $GATE_DIR/ettun-transport-exec &&
    ! -L $GATE_DIR/ettun-transport-exec &&
    $(gate_sha256 "$GATE_DIR/ettun-transport-exec") == "$transport_digest" ]] ||
    publish_drift ettun-generation-drift
  unset ETTUN_ET
  ETTUN_TRANSPORT=$GATE_DIR/ettun-transport-exec
  export ETTUN_TRANSPORT
else
  [[ ! -e $GATE_DIR/ettun-transport-source ]] ||
    publish_drift ettun-generation-drift
  read_source "$GATE_DIR/ettun-et-source" ettun-et-binary-drift \
    >/dev/null || exit $?
  [[ -f $GATE_DIR/ettun-et-gate && -x $GATE_DIR/ettun-et-gate &&
    ! -L $GATE_DIR/ettun-et-gate ]] ||
    publish_drift ettun-generation-drift
  unset ETTUN_TRANSPORT
  ETTUN_ET=$GATE_DIR/ettun-et-gate
  export ETTUN_ET
fi

argv=()
while IFS= read -r element || [[ -n $element ]]; do
  [[ -n $element && $element != *$'\t'* && $element != *$'\r'* ]] ||
    publish_drift ettun-generation-drift
  argv+=("$element")
done <"$GATE_DIR/ettun-argv"
[[ -n ${argv[0]+set} ]] || publish_drift ettun-generation-drift
[[ ${#argv[@]} -eq 4 && -d $GATE_DIR/ettun-tmp &&
  ! -L $GATE_DIR/ettun-tmp ]] || publish_drift ettun-generation-drift

# Ambient knobs would change remote ownership without being present in the
# immutable manifest. The selected transport was pinned above; temporary state
# remains generation-private.
unset ETTUN_CLIENT_ID ETTUN_BOOTSTRAP_TIMEOUT
TMPDIR=$GATE_DIR/ettun-tmp
TMP=$TMPDIR
TEMP=$TMPDIR
export TMPDIR TMP TEMP

rm -f -- "$DRIFT_FILE"
exec "$ettun_path" "${argv[@]}"
