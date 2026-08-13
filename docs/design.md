# Design contract

## Scope

`fwdports` supervises one selected profile in one owned tmux session. Profiles
are alternative desired states, not concurrent instances. The public core owns
configuration, lifecycle, observation, repair, and built-in transport behavior;
consumer-specific policy belongs in profile data or a trusted executable
driver.

The built-ins are `ssh`, explicit `autossh`, and explicit stock Eternal
Terminal (`et`). The executable driver API is the only extension mechanism.
There are no sourced plug-ins, raw shell command options, or evaluated
configuration fragments.

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

The driver is implemented and tested against the public tagged ET 7.0.0
contract. Later releases fail closed until their internal SSH launch behavior
is reviewed as well. It runs with no terminal, disables telemetry, sends logs
to the owned tmux pane, and keeps temporary state under the private generation.
Hostnames, IPv4 addresses, SSH aliases, users, and an optional ET server `port`
are supported. Raw IPv6 literals are deliberately deferred; an SSH alias may
resolve to IPv6 without exposing ET's ambiguous literal parsing to the
configuration surface. Ambient `ProxyJump`, `ProxyCommand`, forwarding, remote
commands, agent forwarding, and `SetEnv` are rejected: ET consumes those itself,
outside the manifest. Jump-host support is deferred until both ET SSH bootstrap
calls can be bound and tested independently.

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
live; ET owns reconnects inside its single foreground process; an external
driver owns retry policy inside its foreground `run` process.

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
session, PID/start identity, tty, SID, and PGID evidence. Cleanup revalidates
that evidence before signalling the owned foreground process group. Ambiguous
evidence is retained for manual diagnosis rather than guessed away.

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
