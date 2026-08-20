# fwdports

![CI](https://github.com/cgraf78/fwdports/actions/workflows/ci.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D3.2-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Termux-lightgrey.svg)](#)

`fwdports` keeps a declared set of port forwards alive in one inspectable tmux
session. It uses ordinary foreground OpenSSH by default, supports autossh when
explicitly selected, supports Eternal Terminal 7.0.0 or newer for resilient
direct-host tunnels, supports the public `ettun` relay engine for destinations
reached through an ET host, and lets trusted local executables provide other
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
mean `ssh`; select `autossh` explicitly when its monitor semantics are wanted,
select `et` for an Eternal Terminal 7.0.0-or-newer direct connection, or
select `ettun` for relay-backed local and/or reverse forwards through an ET
host.
See [the design contract](docs/design.md) and the directly tested
[examples](examples/README.md) for the complete grammar.

## Usage

```bash
fwdports                       # start the default profile
fwdports host.example.com      # override the profile target
fwdports --profile local-dev
fwdports status
fwdports inspect
fwdports attach
fwdports stop
```

After a successful start, `fwdports` prints the normalized standard forward
records from the immutable generation manifest, without guessing at endpoint
direction beyond the declared `local` or `remote` kind:

```text
fwdports: started profile local-dev
fwdports: forwards
  web [ssh] local 127.0.0.1:8080:127.0.0.1:8080
```

The same compact summary is printed when a matching start is a no-churn
success, so it still describes the active generation. `fwdports status`
remains a single machine-friendly state token. A profile with no standard
forward records says so explicitly; an executable driver may still implement
additional behavior through its own manifest keys.

One owned tmux session is supported. Repeating `start` with the same desired
state is a no-churn success while the generation is live and its checks pass.
A dead generation, dead controller, or restart-policy health failure is
replaced sequentially; `preserve` keeps a still-live degraded generation.
A differing configuration requires `--force`, which completes an authenticated
stop before starting the replacement. Two generations never overlap.

`fwdports attach` connects to that session through its private socket while
retaining the user's normal tmux configuration, including mouse, copy-mode,
key, and style settings. Transport panes live in a `forwards` window, use an
even vertical layout, and show `LEG [DRIVER]` on their borders. The lifecycle
controller runs separately in a `control` window, and each attach refocuses an
authenticated transport pane instead of presenting controller output.
The private server overrides only lifecycle-critical tmux settings:
`destroy-unattached` and `exit-unattached` cannot end supervision when a client
disconnects, while `exit-empty` retires the server after its last owned session
ends.

`fwdports status` intentionally remains a single machine-readable state token.
For interactive diagnosis, `fwdports inspect` authenticates the active
generation and reports the overall state, controller and transport pane/window
identities, per-leg supervisor or driver liveness, declared standard forwards,
and a bounded point-in-time result for each configured check. Checks are
described as local TCP connect probes: they show whether the configured address
accepted a connection from the machine running `fwdports`, not that traffic
reached a tunnel's final destination or exercised an application protocol.

## Drivers

Built-in `ssh`, `autossh`, `et`, and `ettun` share the standard forward record
names where their transport semantics overlap.
ET uses an explicit four-part network form. It accepts a direct host or one
single-hop `ProxyJump` SSH alias; the destination and jump-host configurations
and ET's two SSH call shapes are bound separately. `ProxyCommand`, multi-hop
jumps, and other configuration that ET would turn into undeclared behavior are
rejected.
Literal IPv6 targets are deferred; use an SSH alias for an IPv6 host. The
`ettun` built-in accepts at most one loopback-bound `local-forward` and at most
one loopback-bound `remote-forward`, with at least one route required.
Local-only profiles retain `ettun VIA LOCAL_PORT TARGET TARGET_PORT`; reverse
or mixed profiles use ettun's explicit route form. It resolves and pins both
`ettun` and its selected transport before creating a tmux session. The
engine and any custom adapter run from generation-owned snapshots, so worker
re-execs and later reconnects cannot adopt an upgrade halfway through the
generation. By default the transport is stock ET 7.0.0 behind the same fixed
`TERM`, private SSH gate, ambient-configuration checks, and telemetry controls
as the direct ET built-in. An optional `transport` setting may name an
executable adapter that supports the noninteractive
`--fwdports-validate` dependency check described in the design contract.
Reverse routes additionally require the adapter's `connect-v2` capability.
An adapter may declare `fwdports-prepare-v1` to receive a foreground
preparation call after every leg validates and before tmux starts; this keeps
interactive authentication on the invoking terminal.
For every generation, fwdports assigns each ettun leg a distinct version-one
remote-port slot and excludes slots implied by every declared route endpoint
port. The immutable launch gate pins that allocation, so concurrently started
legs cannot select overlapping generated relay/control palettes. Adapters that
declare `single-invocation-v1` are also pinned to one invocation; an external
authenticated collision then asks the owning command to restart instead of
repeating adapter authentication.
See the exact transport limits in [the design contract](docs/design.md).
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
- Eternal Terminal 7.0.0 or newer only for profiles that select `et`
- `ettun` and either Eternal Terminal 7.0.0 or newer, or a validated adapter,
  only for profiles that select `ettun`
- base64, gzip, mkfifo, od, and tee for profiles that select `ettun`
- Python 3.9 or newer with `os.getsid` support on macOS only for profiles that select
  `ettun`

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
