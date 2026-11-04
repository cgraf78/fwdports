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

jump_selector=
[[ -f $GATE_DIR/et-ssh-proxyjump && ! -L $GATE_DIR/et-ssh-proxyjump ]] ||
  publish_drift ettun-et-generation-drift
if [[ -s $GATE_DIR/et-ssh-proxyjump ]]; then
  plan_target=
  destination_endpoint=
  jump_endpoint=
  plan_records=0
  while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
    plan_records=$((plan_records + 1))
    case "$kind" in
      target) plan_target=$value ;;
      destination) destination_endpoint=$value ;;
      jump-selector) jump_selector=$value ;;
      jump-endpoint) jump_endpoint=$value ;;
      *) publish_drift ettun-et-generation-drift ;;
    esac
  done <"$GATE_DIR/et-ssh-proxyjump"
  [[ $plan_records -eq 4 && $plan_target == "$target" &&
    -n $destination_endpoint && -n $jump_selector && -n $jump_endpoint &&
    $jump_selector != *$'\t'* &&
    $jump_selector != *$'\r'* ]] ||
    publish_drift ettun-et-generation-drift
fi

et_argv=("$@")
if [[ -n $jump_selector ]]; then
  [[ $# -ge 2 && ${1:-} == --jumphost && ${2:-} == "$jump_selector" ]] ||
    publish_drift ettun-et-generation-drift
  shift 2
elif [[ ${1:-} == --jumphost ]]; then
  publish_drift ettun-et-generation-drift
fi

# These are the reviewed stock-ET call shapes from the authenticated public
# ettun launcher. Every route carries the private ordinary tunnel used for
# lifecycle control; a reverse route adds one fixed-position reverse pair. A
# future shape fails closed until its SSH/configuration behavior is reviewed.
#
# Current ettun uses long options and starts the remote login shell through
# this exact terminal path, so NO_TMUX=1 is set before startup files run. The
# value is remote shell text, so it is pinned literally. ettun and fwdports
# update independently, and a generation snapshots whichever ettun is
# installed, so the earlier short-option shapes (from ettun before
# cgraf78/ettun#34) stay accepted until every installation runs an ettun that
# builds the long form; then delete them. ET 7.1 reads -t as a pty request
# rather than a tunnel, so a value there could become an option; no reviewed
# ettun builds an option-like value, so none is accepted in any shape.
ETTUN_TERMINAL_PATH='env NO_TMUX=1 etterminal'
et_shape_valid=0
if [[ $# -eq 11 && ${1:-} == --no-terminal && ${2:-} == --no-persist &&
  ${3:-} == --keepalive && ${4:-} == 5 && ${5:-} == --terminal-path &&
  ${6:-} == "$ETTUN_TERMINAL_PATH" && ${7:-} == --tunnel &&
  -n ${8:-} && ${8:-} != -* && ${9:-} == --command &&
  -n ${10:-} && ${10:-} != -* && ${11:-} == "$target" ]]; then
  et_shape_valid=1
elif [[ $# -eq 13 && ${1:-} == --no-terminal && ${2:-} == --no-persist &&
  ${3:-} == --keepalive && ${4:-} == 5 && ${5:-} == --terminal-path &&
  ${6:-} == "$ETTUN_TERMINAL_PATH" && ${7:-} == --tunnel &&
  -n ${8:-} && ${8:-} != -* && ${9:-} == --reversetunnel &&
  -n ${10:-} && ${10:-} != -* && ${11:-} == --command &&
  -n ${12:-} && ${12:-} != -* && ${13:-} == "$target" ]]; then
  et_shape_valid=1
elif [[ $# -eq 8 && ${1:-} == -N && ${2:-} == --keepalive &&
  ${3:-} == 5 && ${4:-} == -t && -n ${5:-} && ${5:-} != -* &&
  ${6:-} == --command && -n ${7:-} && ${7:-} != -* &&
  ${8:-} == "$target" ]]; then
  et_shape_valid=1
elif [[ $# -eq 10 && ${1:-} == -N && ${2:-} == --keepalive &&
  ${3:-} == 5 && ${4:-} == -t && -n ${5:-} && ${5:-} != -* &&
  ${6:-} == -r && -n ${7:-} && ${7:-} != -* && ${8:-} == --command &&
  -n ${9:-} && ${9:-} != -* && ${10:-} == "$target" ]]; then
  et_shape_valid=1
fi
if [[ $et_shape_valid -ne 1 ]]; then
  # The pane shows only this line before it exits; the drift class names it.
  printf 'fwdports: ettun passed an unreviewed ET argv shape; update fwdports and ettun together\n' >&2
  publish_drift ettun-et-generation-drift
fi

"$GATE_DIR/et-ssh-ambient/ssh-gate" --check-only "$target" || exit $?
if [[ -n $jump_selector ]]; then
  "$GATE_DIR/et-ssh-jump-ambient/ssh-gate" --check-only \
    "$jump_selector" || exit $?
fi

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
exec "$et_path" --telemetry=false "${et_argv[@]}"
