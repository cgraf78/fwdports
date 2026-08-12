#!/usr/bin/env bash
# Private PATH shim for stock ET v7's SSH bootstrap. ET remains responsible for
# constructing its trusted direct-host argv; this shim only pins the executable
# and prepends reviewed safety options through the generation's SSH gate.

set -u

SHIM_DIR=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 70
RUNTIME=$(cd -P -- "$SHIM_DIR/.." && pwd -P) || exit 70
target=$(<"$RUNTIME/et-target") || exit 70

# ProxyJump is rejected during preparation. Tagged ET v7 therefore makes one
# two-argument bootstrap call: its destination and generated remote command.
# A changed internal shape fails closed instead of being guessed into a route.
[[ $# -eq 2 ]] || {
  printf 'fwdports: unsupported stock ET SSH bootstrap shape\n' >&2
  exit 78
}

# Repeat the plain-config gate after ET has parsed that same configuration.
# ClearAllForwardings on the second gate cannot hide a newly imported ET tunnel
# because this check deliberately happens first.
"$RUNTIME/et-ssh-ambient/ssh-gate" --check-only "$target" || exit $?

argv=()
while IFS= read -r element || [[ -n $element ]]; do
  [[ -n $element && $element != *$'\t'* && $element != *$'\r'* ]] || exit 70
  argv+=("$element")
done <"$RUNTIME/et-ssh-argv"
[[ -n ${argv[0]+set} ]] || exit 70

# `$@` is output from the identity-and-digest-bound ET binary. Preserve it as
# argv instead of parsing remote shell text; the wrapper is a transport pin,
# not a second implementation of ET's private bootstrap protocol.
exec "$RUNTIME/et-ssh-bootstrap/ssh-gate" "${argv[@]}" "$@"
