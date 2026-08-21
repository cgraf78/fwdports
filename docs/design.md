# Design contract

## Scope

`fwdports` supervises one selected profile in one owned tmux session. Profiles
are alternative desired states, not concurrent instances. The public core owns
configuration, lifecycle, observation, repair, and built-in transport behavior;
consumer-specific policy belongs in profile data or a trusted executable
driver.

The built-ins are `ssh`, explicit `autossh`, explicit stock Eternal Terminal
(`et`), and explicit public `ettun`. Extensions are executable boundaries: the
versioned driver API adds a complete driver, while an ettun `transport` adapter
supplies ettun's legacy or capability-negotiated connection contract and may
opt into one foreground preparation operation. There are no sourced plug-ins,
raw shell command options, or evaluated configuration fragments.

## Commands

```text
fwdports [start] [TARGET] [--profile NAME] [--config FILE] [--force]
fwdports status
fwdports inspect
fwdports stop
fwdports attach
fwdports --version
fwdports --driver-api-version
fwdports --help
```

`start` is implied when the first token is a target or an option. `TARGET`
overrides the selected leg target where its driver supports that concept.
Repeated start with an identical fingerprint reconciles the current generation.
A different fingerprint is refused unless `--force`; force stops the old
generation completely before creating the new one.

## Data grammar

Each non-comment line is one whitespace-delimited record:

```text
profile NAME [extends PARENT]
leg LEG [DRIVER]
set LEG KEY VALUE
reset LEG
check LEG loopback PORT [LABEL]
check LEG tcp HOST PORT [LABEL]
failure LEG restart|preserve
```

Names and values use deliberately restricted printable token grammars. V1 has
no quoting, substitutions, includes, or multiline values. Duplicate profiles
or legs, unknown records, unsafe tokens, inheritance cycles, and excessive
inheritance depth fail before any tmux or runtime mutation.

An omitted leg driver means `ssh`. Inheritance resolves parents first. `reset`
clears a previously declared leg's inherited options, checks, and failure
policy while retaining its driver identity. Driver identity cannot change
through inheritance.

## Built-in SSH records

The two SSH-family built-ins understand:

```text
host
local-forward
remote-forward
identity-file
connect-timeout
server-alive-interval
server-alive-count-max
tcp-keep-alive
batch-mode
```

Forward records may repeat; scalar records use the last resolved value. At
least one local or remote forward is required. Core forces foreground,
no-session operation, forward-failure detection, disabled multiplex reuse,
disabled tunnel devices, and disabled local commands. Raw SSH options are not
accepted because they would bypass validation and desired-state fingerprinting.
Built-in legs must use distinct local bind ports across the complete resolved
profile so one successful leg cannot mask another leg's deterministic bind
failure.

## Built-in Eternal Terminal records

The `et` built-in understands:

```text
host
port
local-forward
remote-forward
```

`port` is the ET server port and is deliberately separate from `host`; it
defaults to ET's standard 2022 when omitted. SSH bootstrap ports still come
from SSH configuration, and the remote host must run a compatible `etserver`.
The initial implementation
supports at most one local and one remote forward per leg because ET 7.0.0
accepts one value for each option and does not correctly combine multiple
four-part values. ET forwards therefore use the explicit
`BIND_HOST:BIND_PORT:DESTINATION_HOST:DESTINATION_PORT` network form with
numeric, nonzero ports; its range, socket, and two-part forms are outside the
shared configuration surface. A local forward must have a matching `loopback`
or `tcp` check for its bind host and port. ET can remain alive after a local
bind error, so requiring that check prevents process liveness from being
mistaken for endpoint health.

The driver requires stable ET 7.0.0 or newer and treats later releases as
backward compatible with that command and SSH-bootstrap contract. It rejects
older, prerelease, and malformed versions, then verifies every required public
option before launch. It runs with no terminal, disables telemetry, sends logs
to the owned tmux pane, and keeps temporary state under the private generation.
Hostnames, IPv4 addresses, SSH aliases, users, and an optional ET server `port`
are supported. Raw IPv6 literals are deliberately deferred; an SSH alias may
resolve to IPv6 without exposing ET's ambiguous literal parsing to the
configuration surface. One single-hop `ProxyJump` SSH alias is supported when
the jump resolves directly over its default SSH port. The destination and jump
configurations are bound independently, as are ET's destination-bootstrap and
jump-relay SSH call shapes. `ProxyCommand`, nested or multi-hop jumps,
forwarding, remote commands, agent forwarding, and `SetEnv` remain rejected.

## Built-in ettun records

The `ettun` built-in understands:

```text
host
local-forward (optional)
remote-forward (optional)
transport (optional)
```

`host` is the ET-accessible relay host. At most one `local-forward` and at most
one `remote-forward` may use the explicit
`127.0.0.1:BIND_PORT:TARGET:TARGET_PORT` form; at least one route is required.
Direct local-only profiles retain the public
`ettun VIA LOCAL_PORT TARGET TARGET_PORT` interface. ProxyJump, reverse-only,
and mixed profiles use ettun's explicit option groups. Non-loopback
binds, sockets, ranges, and raw IPv6 literals are rejected. A matching local
check is required whenever a local route exists so process liveness cannot be
reported as endpoint health.

Preparation resolves and authenticates both the public `ettun` executable and
its selected transport before any tmux session or earlier leg starts. With no
`transport` record, fwdports selects stock ET 7.0.0 plus the exact OpenSSH
bootstrap and requires a direct-host-safe `host`. When that host resolves to a
validated single-hop `ProxyJump`, fwdports records `--jump-host` in the public
ettun argv rather than hiding route selection inside the nested ET executable.
The nested gate still verifies that ettun's resulting `--jumphost` argument
and both SSH configurations match the prepared route. It also checks ettun's
non-core local commands (base64, gzip, mkfifo, od, and tee) during dependency
preflight. On macOS it additionally resolves the exact Python 3.9-or-newer
backend reported by an isolated interpreter, runs the installed session
enumerator's bounded `os.getsid` capability probe in isolated mode, and
snapshots the helper plus backend identity and digest into the generation.
Standard `admin`-group-writable macOS application and package-manager ancestry
is accepted only when the current user belongs to that root-capable group;
other shared groups and non-sticky world-writable ancestry remain invalid. The
ordinary trusted-owner sticky-directory exception is unchanged. A declared
adapter must be one executable token, must remain in the foreground when called
by ettun, must not call `setsid`, daemonize, change real user identity, or
otherwise escape the pane process session, and must implement a noninteractive
`--fwdports-validate` call that returns success only when all of its own nested
dependencies are usable. Validation may write actionable diagnostics to
standard error; its standard output is ignored.

Adapter capabilities are queried noninteractively with
`--ettun-capabilities` and retained as a bounded, validated generation record.
A reverse route requires `connect-v2`. If the adapter also declares
`fwdports-prepare-v1`, fwdports invokes the immutable adapter snapshot as
`ADAPTER --fwdports-prepare-v1 MANIFEST LEG RUNTIME_DIR` after every leg has
validated and before creating tmux. That operation inherits the invoking
terminal, may write private state only beneath its runtime directory, and must
return synchronously without surviving descendants. Adapters without the
capability retain the existing noninteractive start path.

The public engine must advertise `remote-port-slot-v1`. Before foreground
preparation, fwdports assigns every ettun leg one distinct slot from 0 through
818 in canonical manifest order. Assignment starts from the manifest digest,
uses deterministic open addressing, and excludes the slot residue of every
declared route endpoint port in the generated range. The engine maps
attempt, role, and slot as
`49152 + (attempt * 4 + role) * 819 + slot`, partitioning 16,380 ports across
five attempts and four remote roles. Its local control listener remains in the
same slot while avoiding the current remote tuple. Exhaustion fails before any
interactive preparation or tmux creation.

Preparation copies the engine and any selected adapter into generation-owned
snapshots after before/after identity and digest checks. The generation gate
rechecks the installed executable identities and hashes immediately before
launch, executes the engine snapshot, removes ambient ettun transport and
identity and allocation overrides, exports only the generation's slot and
adapter snapshot, and keeps temporary state generation-private. An authenticated
`single-invocation-v1` capability is converted into a pinned engine assertion;
ambient assertions are removed. That keeps worker re-execs and later adapter
calls on one immutable set of bytes and one prepared retry policy. The stock-ET
path exports a generation-owned ET
wrapper instead of the raw executable. That wrapper fixes `TERM`, disables
telemetry, binds and rechecks ET's effective SSH view, and routes the reviewed
bootstrap shape through the private hardened SSH shim. `ettun` owns its
reconnect and authenticated relay-cleanup policy; fwdports adds no second
retry loop.

## Status vocabulary

- `starting`: a verified pending generation has not become active.
- `healthy`: the driver is live and every configured service check passes.
- `live/unverified`: the driver is live and has no configured service check.
- `degraded`: the driver is live but a configured service check fails.
- `down`: the driver is not live.
- `controller-down`: active legs may remain, but observation needs an explicit
  `start` to rebuild the generation.
- `stopping`: replacement is disabled while authenticated cleanup is incomplete.

Process or monitor liveness is never reported as endpoint health.

`status` emits exactly one vocabulary token for scripts. `inspect` is the
human-readable companion: it authenticates the active pointer and manifest
before emitting a report, then shows controller and leg tmux identities,
supervisor or driver-reported liveness, standard forwards, and a bounded
point-in-time result for every normalized check. A configured check is always
labeled as a local TCP connect probe. It is not described as end-to-end tunnel
or application health because the probe sends no payload and cannot establish
either claim. Built-in panes are labeled as live supervisors rather than live
transports because direct SSH may be between retry attempts.

## Reconciliation

Each foreground transport owns reconnect behavior while its tmux pane remains
alive. Direct SSH retries with a 1, 2, 4, 8, 16, 30-second cap and resets its
backoff after stable operation. Autossh owns child retries while its monitor is
live; ET and ettun own reconnects inside their single foreground processes; an
external driver owns retry policy inside its foreground `run` process.

The controller observes configured service checks and publishes status; it does
not mutate transport panes in the background. An explicit matching `start`
retains a live healthy or unchecked generation. It also retains a still-live
degraded generation only when every declared leg uses `preserve`. Otherwise,
or when a pane/controller is dead, core authenticates and removes the complete
generation before starting its replacement. This whole-generation transaction
is intentionally simpler and safer than partially rewriting a running graph.

Health probes use elapsed condition-loop ticks rather than wall-clock
arithmetic so clock changes cannot skip or extend observations. Generation
invalidation cancels every pending wait.

## State model

Each start creates a stable, never-renamed random generation directory. Its
manifest is immutable; its control file is atomically replaceable observed
state. It stores only the lifecycle phase, desired state, controller identity,
and latest probe result; transport retry counters stay local to the transport
that actually owns them. Small `pending` and `active` files identify a
generation plus manifest digest. A fully written owner record is published by
an atomic, relative symlink to claim the lifecycle lock. The pointer is
accepted only when its in-root candidate name, protected file, embedded nonce,
and repeated target read agree. This avoids both an ownerless lock state and a
hard-link dependency that Android application filesystems cannot provide.

Tmux sessions carry a random generation nonce at creation. Core records pane,
session, PID/start identity, tty, platform session metadata, and PGID evidence.
Cleanup revalidates that evidence before signalling the owned foreground
process group. For ettun, which creates additional worker process groups in
the same session, tmux's authenticated pane leader PID is the kernel SID
anchor. Linux and Termux select that SID from one strict `ps` snapshot. Darwin's
sanitized `ps sess` pointer is not a POSIX SID, so a generation-owned Python
helper validates a same-real-UID `ps` snapshot and queries each PID with
`os.getsid`. Each scan rechecks both the helper and interpreter identities and
digests, and Python isolated mode excludes ambient startup customization. The
probe child's lifetime is tied to a parent-owned pipe so interruption cannot
leave a detached probe session behind. Two complete scans with no live member
are required before absence is accepted. Zombie and dead rows remain ownership
evidence but are excluded from liveness because they cannot execute or retain a
forwarding socket. Cleanup then uses ettun's bounded first- and second-Ctrl-C
contract through the authenticated tmux pane. It exits copy mode before each
interrupt so tmux cannot consume the stop request as a mode key. The generation
is removable only after two complete scans find no live session member.
Ambiguous evidence is retained for manual diagnosis rather than guessed away.

The explicit tmux socket, cleared inherited client variables, session nonce,
and recorded IDs provide isolation and lifecycle authority. The private server
still loads the user's normal tmux configuration so copy-mode, mouse, keys, and
styles behave consistently with their other sessions. Lifecycle-owned display
structure is narrower: labeled transport panes share an even vertical
`forwards` window, while the controller occupies a separate `control` window.
Attach authenticates a recorded transport pane and selects its window before
connecting. The private server forces `destroy-unattached` and
`exit-unattached` off and `exit-empty` on because detached supervision and
server retirement are lifecycle invariants, not presentation preferences.

## Compatibility

The implementation targets Bash 3.2 syntax and provides adapters for BSD/GNU
`stat`, SHA tools, canonicalization, process tables, and netcat variants.
Published numeric tool minimums remain conditional on exact-version CI lanes
covering every relied-on feature.
