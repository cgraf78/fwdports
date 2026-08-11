# Design contract

## Scope

`fwdports` supervises one selected profile in one owned tmux session. Profiles
are alternative desired states, not concurrent instances. The public core owns
configuration, lifecycle, observation, repair, and built-in SSH behavior;
consumer-specific policy belongs in profile data or a trusted executable
driver.

The v1 built-ins are `ssh` and explicit `autossh`. The executable driver API is
the only extension mechanism. There are no sourced plug-ins, raw shell command
options, or evaluated configuration fragments.

## Commands

```text
fwdports [start] [TARGET] [--profile NAME] [--config FILE] [--force]
fwdports status
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

Both built-ins understand:

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

## Reconciliation

Each foreground transport owns reconnect behavior while its tmux pane remains
alive. Direct SSH retries with a 1, 2, 4, 8, 16, 30-second cap and resets its
backoff after stable operation. Autossh owns child retries while its monitor is
live; an external driver owns retry policy inside its foreground `run` process.

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
generation plus manifest digest. A fully written owner record is hard-linked
atomically to claim the lifecycle lock, avoiding an ownerless lock state.

Tmux sessions carry a random generation nonce at creation. Core records pane,
session, PID/start identity, tty, SID, and PGID evidence. Cleanup revalidates
that evidence before signalling the owned foreground process group. Ambiguous
evidence is retained for manual diagnosis rather than guessed away.

## Compatibility

The implementation targets Bash 3.2 syntax and provides adapters for BSD/GNU
`stat`, SHA tools, canonicalization, process tables, and netcat variants.
Published numeric tool minimums remain conditional on exact-version CI lanes
covering every relied-on feature.
