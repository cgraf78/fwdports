# Runtime library ownership

These Bash 3.2-compatible modules implement reusable `fwdports` behavior:

- `config.sh` parses and resolves data-only profiles.
- `drivers.sh` owns built-in SSH/autossh validation and argv construction.
- `driver-api.sh` owns trusted external-driver discovery and invocation.
- `runtime.sh` owns XDG state, generations, locks, manifests, and pointers.
- `tmux.sh` owns direct-argv session and pane operations.
- `health.sh` owns pure health and backoff state transitions.

Modules are implementation details, not a general sourced-shell API. The
supported extension boundary is the executable driver protocol documented in
`docs/drivers.md`. Keeping that boundary process-based prevents a driver from
silently changing the caller's traps, shell options, variables, or working
directory.
