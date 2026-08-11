# Executable driver API v1

External drivers are trusted, self-contained executable files in
`${XDG_CONFIG_HOME:-$HOME/.config}/fwdports/drivers.d/`. A driver name is a
restricted identifier. The built-in names `ssh` and `autossh` are reserved and
cannot be shadowed.

Core validates and copies the exact executable into the stable generation
before invoking it. The generation continues to use that immutable snapshot if
the configured source later changes or disappears. Sibling files are not
copied; a driver with ambient dependencies must validate them explicitly.

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
  to request verified pane-process liveness only. It must not mutate.
- `cleanup` is bounded and idempotent before or after pane creation. It may
  remove driver-owned state, but process signalling authority always remains
  with core ownership checks.

All operations receive fixed argv paths. Secrets and options are never passed
through environment variables, tmux metadata, shell command strings, or process
titles. The immutable manifest uses a versioned tab-delimited schema whose
values cannot contain tabs or newlines.

`validate`, `is-live`, and `cleanup` must return synchronously without surviving
descendants. All validation completes before any prepare call. Preparation or
start failure invokes cleanup in reverse order.

See `examples/drivers.d/example` for a harmless executable contract example.
