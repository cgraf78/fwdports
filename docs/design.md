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

## Status vocabulary

- `starting`: a verified pending generation has not become active.
- `backoff`: a direct SSH restart is waiting for its next bounded attempt.
- `healthy`: the driver is live and every configured service check passes.
- `live/unverified`: the driver is live and has no configured service check.
- `degraded`: the driver is live but a configured service check fails.
- `down`: the driver is not live.
- `controller-down`: active legs may remain, but observation needs an explicit
  `start` to repair the controller.
- `stopping`: repair is disabled while authenticated cleanup is incomplete.
- `failed`: a verified generation has an actionable start/controller failure.

Process or monitor liveness is never reported as endpoint health.

## Reconciliation

Healthy or unchecked live legs are retained. A live degraded leg is recycled
only when its policy is `restart`; `preserve` applies only while a transport is
still live. Every dead leg is restarted with bounded backoff. Direct SSH uses
elapsed controller ticks with a 1, 2, 4, 8, 16, 30 cap and resets after stable
operation. Autossh owns child retries while its monitor is live.

Health probes use elapsed condition-loop ticks rather than wall-clock
arithmetic so clock changes cannot skip or extend policy transitions.
Generation invalidation cancels every pending wait.

## State model

Each start creates a stable, never-renamed random generation directory. Its
manifest is immutable; its control file is atomically replaceable observed
state. Small `pending` and `active` files identify a generation plus manifest
digest. A fully written owner record is hard-linked atomically to claim the
lifecycle lock, avoiding an ownerless lock state.

Tmux sessions carry a random generation nonce at creation. Core records pane,
session, PID/start identity, tty, SID, and PGID evidence. Cleanup revalidates
that evidence before signalling the owned foreground process group. Ambiguous
evidence is retained for manual diagnosis rather than guessed away.

## Compatibility

The implementation targets Bash 3.2 syntax and provides adapters for BSD/GNU
`stat`, SHA tools, canonicalization, process tables, and netcat variants.
Published numeric tool minimums remain conditional on exact-version CI lanes
covering every relied-on feature.
