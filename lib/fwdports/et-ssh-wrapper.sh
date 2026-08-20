#!/usr/bin/env bash
# Private PATH shim for stock ET v7's SSH bootstrap. ET remains responsible for
# constructing its trusted direct-host argv; this shim only pins the executable
# and prepends reviewed safety options through the generation's SSH gate.

set -u

SHIM_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 70
RUNTIME=$(cd -P -- "$SHIM_DIR/.." && pwd -P) || exit 70
target=$(<"$RUNTIME/et-target") || exit 70

argv=()
while IFS= read -r element || [[ -n $element ]]; do
  [[ -n $element && $element != *$'\t'* && $element != *$'\r'* ]] || exit 70
  argv+=("$element")
done <"$RUNTIME/et-ssh-argv"
[[ -n ${argv[0]+set} ]] || exit 70

[[ -f $RUNTIME/et-ssh-proxyjump && ! -L $RUNTIME/et-ssh-proxyjump ]] || exit 70
if [[ -s $RUNTIME/et-ssh-proxyjump ]]; then
  plan_target=
  destination_endpoint=
  jump_selector=
  jump_endpoint=
  plan_records=0
  while IFS=$'\t' read -r kind value || [[ -n ${kind:-} ]]; do
    plan_records=$((plan_records + 1))
    case "$kind" in
      target) plan_target=$value ;;
      destination) destination_endpoint=$value ;;
      jump-selector) jump_selector=$value ;;
      jump-endpoint) jump_endpoint=$value ;;
      *) exit 70 ;;
    esac
  done <"$RUNTIME/et-ssh-proxyjump"
  [[ $plan_records -eq 4 && $plan_target == "$target" &&
    -n $destination_endpoint && -n $jump_selector && -n $jump_endpoint ]] ||
    exit 70

  # ET v7 makes one destination bootstrap through -J and one stdio relay call
  # to the expanded jump endpoint. Bind both route definitions before either
  # call, then select the separately prepared gate for the observed shape.
  "$RUNTIME/et-ssh-ambient/ssh-gate" --check-only "$target" || exit $?
  "$RUNTIME/et-ssh-jump-ambient/ssh-gate" --check-only \
    "$jump_selector" || exit $?
  if [[ $# -eq 4 && $1 == -J && $2 == "$jump_endpoint" &&
    $3 == "$destination_endpoint" && -n $4 ]]; then
    exec "$RUNTIME/et-ssh-bootstrap/ssh-gate" \
      "${argv[@]}" "$@"
  fi
  if [[ $# -eq 2 && $1 == "$jump_endpoint" && -n $2 ]]; then
    exec "$RUNTIME/et-ssh-jump-bootstrap/ssh-gate" \
      "${argv[@]}" "$@"
  fi
  printf 'fwdports: unsupported stock ET ProxyJump SSH shape\n' >&2
  exit 78
fi

# Without ProxyJump, tagged ET v7 makes one two-argument bootstrap call: its
# destination and generated remote command. A changed internal shape fails
# closed instead of being guessed into a route.
[[ $# -eq 2 ]] || {
  printf 'fwdports: unsupported stock ET SSH bootstrap shape\n' >&2
  exit 78
}

# Repeat the plain-config gate after ET has parsed that same configuration.
# ClearAllForwardings on the second gate cannot hide a newly imported ET tunnel
# because this check deliberately happens first.
"$RUNTIME/et-ssh-ambient/ssh-gate" --check-only "$target" || exit $?

# `$@` is output from the identity-and-digest-bound ET binary. Preserve it as
# argv instead of parsing remote shell text; the wrapper is a transport pin,
# not a second implementation of ET's private bootstrap protocol.
exec "$RUNTIME/et-ssh-bootstrap/ssh-gate" "${argv[@]}" "$@"
