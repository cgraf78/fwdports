#!/usr/bin/env bash
# Publish fwdports from a durable checkout. The command loads its libraries
# from that same checkout, so installation intentionally creates one link and
# never copies a second runtime tree that could drift independently.

set -euo pipefail

PREFIX=${PREFIX:-$HOME/.local}
BIN_DIR=${BIN_DIR:-$PREFIX/bin}
ROOT=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
COMMAND_SOURCE="$ROOT/bin/fwdports"

# Validate the complete currently published inventory before creating a
# destination directory. Later library additions extend this preflight list;
# an incomplete checkout must never become a partially usable installation.
if [[ ! -f "$COMMAND_SOURCE" || ! -x "$COMMAND_SOURCE" ]]; then
  printf 'fwdports: command source is not executable: %s\n' \
    "$COMMAND_SOURCE" >&2
  exit 1
fi

# Keep this inventory explicit rather than globbing. Adding a runtime module
# should require an installer review, and unrelated files under lib/ must never
# become an accidental part of the published contract.
LIBRARY_SOURCES=(
  "$ROOT/lib/fwdports/config.sh"
  "$ROOT/lib/fwdports/drivers.sh"
  "$ROOT/lib/fwdports/ssh-gate.sh"
)
for source in "${LIBRARY_SOURCES[@]}"; do
  if [[ ! -f "$source" ]]; then
    printf 'fwdports: library source is missing: %s\n' "$source" >&2
    exit 1
  fi
done

# Existing symlinks are installer-owned publication points and may be
# retargeted. A real file or directory may belong to the user or another
# package, so refusing it is safer than guessing ownership from its name.
COMMAND_TARGET="$BIN_DIR/fwdports"
if [[ (-e "$COMMAND_TARGET" || -L "$COMMAND_TARGET") &&
  ! -L "$COMMAND_TARGET" ]]; then
  printf 'fwdports: refusing to replace non-symlink path: %s\n' \
    "$COMMAND_TARGET" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"

# Publish through a temporary symlink on the destination filesystem. A failed
# preparation leaves the prior destination untouched; the final rename is the
# only operation that changes the public command path.
TEMP_LINK=$(mktemp "$BIN_DIR/.fwdports.link.XXXXXXXX") || {
  printf 'fwdports: cannot create temporary link in %s\n' "$BIN_DIR" >&2
  exit 1
}
cleanup_temp_link() {
  rm -f -- "$TEMP_LINK"
}
trap cleanup_temp_link EXIT HUP INT TERM
ln -sfn -- "$COMMAND_SOURCE" "$TEMP_LINK"
mv -f -- "$TEMP_LINK" "$COMMAND_TARGET"
trap - EXIT HUP INT TERM

printf 'installed fwdports to %s\n' "$COMMAND_TARGET"
