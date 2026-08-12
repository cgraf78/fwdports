#!/usr/bin/env bash
# Generation-owned stock ET launch gate. The selected ET binary is a trusted
# same-user dependency, but reconnecting port forwards must not silently adopt
# replacement bytes or newly side-effecting SSH configuration. This copied
# gate authenticates both immediately before the one foreground ET exec.

set -u
umask 077

GATE_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 70
SOURCE_FILE=$GATE_DIR/et-source
DRIFT_FILE=$GATE_DIR/et-drift

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

  tmp=$(mktemp "$GATE_DIR/.et-drift.XXXXXXXX") || exit 78
  if ! printf '%s\n' "$class" >"$tmp" || ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$DRIFT_FILE"; then
    rm -f -- "$tmp"
  fi
  exit 78
}

et_path=
expected_identity=
expected_digest=
while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
  case "$kind" in
    path) et_path=$value ;;
    identity) expected_identity=$value ;;
    digest) expected_digest=$value ;;
  esac
done <"$SOURCE_FILE"

if [[ -z $et_path || -z $expected_identity ||
  ! $expected_digest =~ ^[0-9a-f]{64}$ ||
  ! -f $et_path || ! -x $et_path ]]; then
  publish_drift et-binary-drift
fi
actual_identity=$(gate_stat_identity "$et_path") ||
  publish_drift et-binary-drift
[[ $actual_identity == "$expected_identity" ]] ||
  publish_drift et-binary-drift
actual_digest=$(gate_sha256 "$et_path") || publish_drift et-binary-drift
[[ $actual_digest == "$expected_digest" ]] || publish_drift et-binary-drift

target=$(<"$GATE_DIR/et-target") || publish_drift et-generation-drift
argv=()
while IFS= read -r element || [[ -n $element ]]; do
  [[ -n $element && $element != *$'\t'* && $element != *$'\r'* ]] ||
    publish_drift et-generation-drift
  argv+=("$element")
done <"$GATE_DIR/et-argv"
[[ -n $target && -n ${argv[0]+set} ]] ||
  publish_drift et-generation-drift

# ET parses SSH configuration itself before invoking ssh. Check the plain view
# now, then let the private ssh shim repeat the check after that parse and just
# before the hardened bootstrap. This closes the meaningful configuration
# drift window without trying to sandbox trusted same-UID code.
"$GATE_DIR/et-ssh-ambient/ssh-gate" --check-only "$target" || exit $?

[[ -d $GATE_DIR/et-bin && ! -L $GATE_DIR/et-bin &&
  -x $GATE_DIR/et-bin/ssh && ! -L $GATE_DIR/et-bin/ssh &&
  -d $GATE_DIR/et-tmp && ! -L $GATE_DIR/et-tmp ]] ||
  publish_drift et-generation-drift

# Upstream ET v7 embeds TERM inside a single-quoted remote shell command and
# also consults generic temporary-directory variables even with telemetry off.
# Fixed, private values prevent ambient shell text or shared /tmp state from
# crossing that boundary. ET still writes ordinary diagnostics to the pane.
TERM=xterm-256color
TMPDIR=$GATE_DIR/et-tmp
TMP=$TMPDIR
TEMP=$TMPDIR
PATH=$GATE_DIR/et-bin:${PATH:-/usr/bin:/bin}
export TERM TMPDIR TMP TEMP PATH

rm -f -- "$DRIFT_FILE"
exec "$et_path" "${argv[@]}" "$target"
