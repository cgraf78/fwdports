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

`et-driver-test` binds its fixtures to the public ET 7.0.0 command surface,
exercises the 7.0.0-or-newer version policy, and covers executable/config drift
gates, environment sanitization, and the private SSH shim.
`cli-integration-test` also runs an ET leg through a real isolated tmux server.
The suite does not use a machine-specific ET build as proof of upstream
behavior.

CI separately downloads the publisher's checksummed ET 7.0.0 arm64 package and
runs `support/verify-stock-et-contract.sh` against the real client. That gate
establishes the minimum supported contract; newer stable releases are presumed
backward compatible and still undergo runtime option checks, executable
identity binding, and digest validation. The baseline gate proves the required
CLI flags, PATH-based direct SSH bootstrap, both tunnel option forms,
configured ET port, and bounded TERM behavior rather than letting the hermetic
fakes define the upstream contract. Single-hop ProxyJump call shapes are
covered hermetically; live validation must use an installed SSH configuration
because ET resolves it from the invoking user's passwd home.

Runtime tests deliberately force atomic-replacement races and crash seams.
They distinguish a complete old/new control record—which readers may retry—
from malformed ownership evidence, which must fail closed. Cleanup cases place
sentinels beside generations and behind symlinks so future refactors prove the
destructive boundary rather than merely asserting the expected target vanished.
The process-tree suite also forces the Darwin `os.getsid` adapter on Linux so a
worker that survives pane-leader exit and loses its tty remains observable.

`cli-integration-test` uses a real isolated tmux server and a harmless fake SSH
transport to exercise the installed command path from start through status and
authenticated stop. It also verifies labeled, evenly sized transport panes and
the separate controller window, plus the authenticated human inspection report
without weakening status's one-token contract. `tmux-integration-test`
supplies a temporary normal tmux configuration to prove that mouse and
copy-mode preferences reach the isolated server. `driver-api-test` keeps
external consumers on the fixed argv/file boundary. `examples-test` reads
checked-in examples directly, and `portability-test` names platform adapters
that are easy to regress on macOS. The process-tree suite also exercises the
Darwin helper's isolated startup, generation integrity checks, and
parent-interruption cleanup contract.
