# fwdports

![CI](https://github.com/cgraf78/fwdports/actions/workflows/ci.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`fwdports` keeps a declared set of SSH port forwards alive in one inspectable
tmux session. It uses ordinary foreground OpenSSH by default, supports autossh
when explicitly selected, and lets trusted local executables provide other
transport drivers without putting consumer policy in the core.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cgraf78/fwdports/main/install.sh | bash
```

The installer maintains a checkout under
`${XDG_DATA_HOME:-$HOME/.local/share}/cgraf78/checkouts/fwdports` and publishes
one symlink at `${PREFIX:-$HOME/.local}/bin/fwdports`. The command and its
`lib/fwdports` modules therefore always come from the same revision; there is
no copied library tree that can drift from the executable.

To own the checkout yourself:

```bash
git clone https://github.com/cgraf78/fwdports.git
cd fwdports
bash install.sh
```

The installer may retarget an existing symlink, but it refuses to replace a
real file or directory. `BIN_DIR` selects an explicit command destination.

## Configuration

The default data-only configuration is
`${XDG_CONFIG_HOME:-$HOME/.config}/fwdports/tunnels.conf`:

```text
profile local-dev
leg web
set web host shell.example.com
set web local-forward 127.0.0.1:8080:127.0.0.1:8080
check web loopback 8080 web
```

Configuration is parsed as records, never evaluated as shell. Omitted drivers
mean `ssh`; select `autossh` explicitly when its monitor semantics are wanted.
See [the design contract](docs/design.md) and the directly tested
[examples](examples/README.md) for the complete grammar.

## Usage

```bash
fwdports                       # start the default profile
fwdports host.example.com      # override the profile target
fwdports --profile local-dev
fwdports status
fwdports attach
fwdports stop
```

One owned tmux session is supported. Repeating `start` with the same desired
state is a no-churn success while the generation is live and its checks pass.
A dead generation, dead controller, or restart-policy health failure is
replaced sequentially; `preserve` keeps a still-live degraded generation.
A differing configuration requires `--force`, which completes an authenticated
stop before starting the replacement. Two generations never overlap.

## Drivers

Built-in `ssh` and `autossh` share the same validated forwarding model.
Additional drivers are trusted, single-file executables under
`${XDG_CONFIG_HOME:-$HOME/.config}/fwdports/drivers.d/`. Their versioned argv
protocol is documented in [docs/drivers.md](docs/drivers.md).

## State and safety

Runtime ownership is recorded under
`${XDG_STATE_HOME:-$HOME/.local/state}/fwdports`. Stable generation directories,
an owner-bearing lock, immutable manifests, atomic pointer files, and tmux
nonces keep cleanup scoped to processes that `fwdports` can reauthenticate.
Unknown or incomplete ownership evidence fails closed rather than killing by
name, port, or a stale PID. See [docs/security.md](docs/security.md).

## Requirements

- Bash 3.2 or newer
- tmux
- OpenSSH
- netcat
- `lsof` or `ss` for local-listener diagnostics
- autossh only for profiles that select it

Numeric minimums are claimed only for versions exercised by CI. Current
platform results and intentional limitations are kept in the design document.

## Development

```bash
bash test/run
```

The suites use isolated HOME/XDG roots, tmux sockets, and loopback listeners.
Process and tmux suites run sequentially so timing assertions measure the code
rather than contention between tests. See [test/README.md](test/README.md).

## License

MIT — see [LICENSE](LICENSE).
