# Test ownership

`test/run` executes focused behavior suites sequentially. Each suite accepts an
optional exact case name, for example:

```bash
bash test/install-test delegate-direct
```

An unknown case fails. This makes each red/green step observable and prevents a
misspelled filter from reporting an empty success.

The shared harness creates one validated temporary root per suite and deletes
only that root. Runtime suites additionally provide isolated HOME/XDG paths,
tmux sockets, SSH configuration, loopback listeners, and cleanup traps. They do
not inspect or alter the user's normal tmux server, SSH sessions, or runtime
state.

Process-group, signal, tmux, and listener suites remain sequential because
parallel load weakens their timing and ownership evidence. Fakes are used at
external executable boundaries, while real tmux/process/autossh integration
tests prove the behavior those fakes cannot establish.
