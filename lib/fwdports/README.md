# Runtime library ownership

These Bash 3.2-compatible modules implement reusable `fwdports` behavior:

- `config.sh` parses and resolves data-only profiles.
- `core.sh` composes command-level start/status/stop/attach transactions.
- `controller.sh` gates activation, reports observed state, and resumes only
  generation-authenticated crash cleanup.
- `drivers.sh` owns built-in SSH/autossh validation and argv construction.
- `driver-api.sh` owns trusted external-driver discovery and invocation.
- `builtin-runner.sh` keeps direct SSH alive with bounded backoff and launches
  explicitly selected autossh with a scrubbed environment.
- `health.sh` owns pure health and backoff state transitions.
- `runtime.sh` owns XDG state, generations, locks, manifests, and pointers.
- `tmux.sh` owns direct-argv session and pane operations.

Modules are implementation details, not a general sourced-shell API. The
supported extension boundary is the executable driver protocol documented in
`docs/drivers.md`. Keeping that boundary process-based prevents a driver from
silently changing the caller's traps, shell options, variables, or working
directory.

The split between `runtime.sh`, `tmux.sh`, and `controller.sh` is intentional.
Runtime files establish filesystem authority, tmux/process evidence establishes
signal authority, and the controller combines those proofs only after an
atomic active pointer grants mutation authority. Keeping these layers distinct
makes it harder for a convenient process name, port, or stale PID to become an
accidental cleanup credential.
