# Executable driver API v1

External drivers are trusted, self-contained executable files in
`${XDG_CONFIG_HOME:-$HOME/.config}/fwdports/drivers.d/`. A driver name is a
restricted identifier. The built-in names `ssh`, `autossh`, and `et` are
reserved and cannot be shadowed.

Core validates and copies the exact executable into the stable generation
before invoking it. The generation continues to use that immutable snapshot if
the configured source later changes or disappears. Sibling files are not
copied; a driver with ambient dependencies must validate them explicitly.
Several legs may select the same driver; they share one immutable executable
snapshot but receive separate runtime directories and separate operation calls.

## Operations

```text
DRIVER api-version
DRIVER validate MANIFEST LEG RUNTIME_DIR
DRIVER prepare MANIFEST LEG RUNTIME_DIR
DRIVER run MANIFEST LEG RUNTIME_DIR
DRIVER is-live MANIFEST LEG RUNTIME_DIR PANE_ID
DRIVER cleanup MANIFEST LEG RUNTIME_DIR [PANE_ID]
```

- `api-version` prints exactly `1` without mutation.
- `validate` is bounded, noninteractive, and idempotent. It validates effective
  options and dependencies and writes actionable failures to stderr.
- `prepare` may use the controlling terminal and may write only beneath its
  private mode-0700 leg runtime directory. It must restore terminal state on
  normal, error, and catchable-signal exits.
- `run` is the foreground lifetime process. It must not daemonize or escape the
  pane process group. A wrapper owns, stops, and reaps every helper it creates.
- `is-live` returns zero for driver-proven liveness, one for not live, and two
  to request verified pane-process liveness only. Core consults it only after
  authenticating the pane, and it must not mutate.
- `cleanup` is bounded and idempotent before or after pane creation. During an
  authenticated stop, core may invoke it while the `run` process is still live
  and again after core-owned processes have exited. Crash recovery can repeat
  either invocation. The live invocation lets a driver gracefully retire
  remote resources through an authenticated channel that process-group
  termination would otherwise close; a later invocation removes remaining
  local state. The driver must coordinate access to its own runtime state, must
  not modify core-owned pane evidence, and must return without surviving
  descendants. It may remove driver-owned state, but process signalling
  authority always remains with core ownership checks.

All operations receive fixed argv paths. Secrets and options are never passed
through environment variables, tmux metadata, shell command strings, or process
titles. The immutable manifest uses a versioned tab-delimited schema whose
values cannot contain tabs or newlines.

`validate`, `is-live`, and `cleanup` must bound their own work and return
synchronously without surviving descendants. Drivers are trusted code, so core
does not attempt to sandbox these calls or guess how to kill descendants it did
not create. All validation completes before any prepare call. Preparation or
start failure invokes cleanup in reverse leg order.

See `examples/drivers.d/example` for a harmless executable contract example.
