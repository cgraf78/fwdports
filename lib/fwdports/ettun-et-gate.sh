#!/usr/bin/env bash
# Generation-owned wrapper for ettun's stock ET transport. The authenticated
# ettun launcher owns dynamic tunnel and command arguments; this gate pins the
# ET and SSH executables and applies the same environment/configuration policy
# as the native stock-ET driver immediately before ET runs.

set -u
umask 077

GATE_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 70
SOURCE_FILE=$GATE_DIR/ettun-et-source
DRIFT_FILE=$GATE_DIR/ettun-et-drift

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

  tmp=$(mktemp "$GATE_DIR/.ettun-et-drift.XXXXXXXX") || exit 78
  if ! printf '%s\n' "$class" >"$tmp" || ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$DRIFT_FILE"; then
    rm -f -- "$tmp"
  fi
  exit 78
}

et_path=
expected_identity=
expected_digest=
[[ -f $SOURCE_FILE && ! -L $SOURCE_FILE ]] ||
  publish_drift ettun-et-binary-drift
while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
  case "$kind" in
    path) et_path=$value ;;
    identity) expected_identity=$value ;;
    digest) expected_digest=$value ;;
  esac
done <"$SOURCE_FILE"
[[ -n $et_path && -n $expected_identity &&
  $expected_digest =~ ^[0-9a-f]{64}$ && -f $et_path && -x $et_path ]] ||
  publish_drift ettun-et-binary-drift
[[ $(gate_stat_identity "$et_path") == "$expected_identity" ]] ||
  publish_drift ettun-et-binary-drift
[[ $(gate_sha256 "$et_path") == "$expected_digest" ]] ||
  publish_drift ettun-et-binary-drift

target=
target_records=0
[[ -f $GATE_DIR/et-target && ! -L $GATE_DIR/et-target ]] ||
  publish_drift ettun-et-generation-drift
while IFS= read -r element || [[ -n $element ]]; do
  target_records=$((target_records + 1))
  [[ $target_records -eq 1 && -n $element && $element != *$'\t'* &&
    $element != *$'\r'* ]] || publish_drift ettun-et-generation-drift
  target=$element
done <"$GATE_DIR/et-target"

# These are the reviewed stock-ET call shapes from the authenticated public
# ettun launcher. Every route carries the private ordinary tunnel used for
# lifecycle control; a reverse route adds one fixed-position -r pair. A future
# shape fails closed until its SSH/configuration behavior is reviewed.
et_shape_valid=0
if [[ $# -eq 8 && ${1:-} == -N && ${2:-} == --keepalive &&
  ${3:-} == 5 && ${4:-} == -t && -n ${5:-} &&
  ${6:-} == --command && -n ${7:-} && ${8:-} == "$target" ]]; then
  et_shape_valid=1
elif [[ $# -eq 10 && ${1:-} == -N && ${2:-} == --keepalive &&
  ${3:-} == 5 && ${4:-} == -t && -n ${5:-} &&
  ${6:-} == -r && -n ${7:-} && ${8:-} == --command &&
  -n ${9:-} && ${10:-} == "$target" ]]; then
  et_shape_valid=1
fi
[[ $et_shape_valid -eq 1 ]] || publish_drift ettun-et-generation-drift

"$GATE_DIR/et-ssh-ambient/ssh-gate" --check-only "$target" || exit $?

[[ -d $GATE_DIR/et-bin && ! -L $GATE_DIR/et-bin &&
  -x $GATE_DIR/et-bin/ssh && ! -L $GATE_DIR/et-bin/ssh &&
  -d $GATE_DIR/et-tmp && ! -L $GATE_DIR/et-tmp ]] ||
  publish_drift ettun-et-generation-drift

TERM=xterm-256color
TMPDIR=$GATE_DIR/et-tmp
TMP=$TMPDIR
TEMP=$TMPDIR
PATH=$GATE_DIR/et-bin:${PATH:-/usr/bin:/bin}
export TERM TMPDIR TMP TEMP PATH

rm -f -- "$DRIFT_FILE"
exec "$et_path" --telemetry=false "$@"
