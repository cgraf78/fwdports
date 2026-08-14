# Security and trust model

`fwdports` narrows lifecycle authority; it is not a sandbox for code the user
chooses to install. User SSH configuration and external driver executables are
trusted same-user inputs. The user's normal tmux configuration is trusted too:
the private server loads it for consistent interaction, while the private
socket and cleared inherited client variables keep it separate from the
ordinary tmux server. Lifecycle-critical `destroy-unattached`,
`exit-unattached`, and `exit-empty` values are overridden on that private
server so a presentation preference cannot end supervision or retain a stale
server. Profile data is non-executable but can intentionally expose network
ports, so it still receives strict syntax and path validation.
The private runtime protocol prevents stale cooperating instances from
claiming one another's state; it does not defend against malicious same-UID
code racing filesystem operations, because that code already has authority to
replace the user's configuration, drivers, and state.

## Filesystem trust

Configuration, driver directories, drivers, and canonical targets are checked
for trusted ownership and mode before use. Symlinks are accepted only after
separate link and canonical-target checks so a dotfiles-managed link does not
bypass parent-chain validation. Driver bytes are copied only after before/after
identity checks; replacement during the copy fails before tmux creation.

Built-in executable parents are checked back to the filesystem root. A
structurally recognized `$PREFIX` in an actual Termux runtime is a trust anchor
because Android's app sandbox protects ancestors using policy that ordinary
Unix mode bits cannot represent; the prefix node and every descendant are still
validated. Both Bash's Android `OSTYPE` and the app-data prefix shape must
match; a generic caller-supplied `PREFIX` grants no such exception. Darwin also
accepts an `admin`-group-writable, non-world-writable ancestor only when its
owner is root or the current user and the current user belongs to that standard
root-capable group. This matches standard macOS `/Applications` and
package-manager layouts without extending trust to arbitrary shared groups.

State and runtime roots are mode 0700, generated files use a restrictive
umask, and manifests/control records are mode 0600. Atomic same-directory
renames publish files only after complete content is available.

## Process ownership

Core never kills by program name, argv substring, port number, `pgrep -f`, or a
bare recorded PID. A generation nonce, tmux relationship, PID start identity,
and the relevant tty and process scope must still agree before TERM is sent.
Most drivers are bounded by the pane leader's process group; KILL is used only
after a bounded condition wait and a second ownership check. Public ettun
deliberately creates additional worker process groups, so its boundary is the
complete kernel process session anchored by the authenticated tmux pane leader
PID. Linux and Termux select the SID from a strict `ps` snapshot. On Darwin, a
generation-owned helper filters one same-real-UID snapshot and calls
`os.getsid` for each PID because `ps sess` is a sanitized kernel pointer. The
helper and exact Python backend are identity- and digest-bound to the
generation, revalidated before every scan, and invoked in isolated mode. A
stable launcher cannot redirect later scans to replacement backend bytes. The
probe's detached child also exits when its parent-liveness pipe closes. Every
platform requires two complete scans with no live member. Zombie and dead rows
remain ownership evidence but are inert for cleanup because they cannot execute,
fork, receive another signal, or retain a forwarding socket. Its first terminal
Ctrl-C gets a bounded graceful wait, and a still-authenticated pane receives
ettun's second-Ctrl-C force request. Active copy mode is cancelled in the same
tmux command sequence so it cannot swallow either interrupt. fwdports reports
success only after two complete scans find no live session member and never
substitutes KILL for ettun's cleanup contract. A missing leader, changed session scope,
surviving session, or incomplete enumeration fails closed. An ettun adapter is
trusted to remain foreground and must not call `setsid`, daemonize, change real
user identity, or otherwise escape that process session.

Local-listener discovery is diagnostic only. `lsof` or `ss` can explain a
conflict; when Android hides another process from `lsof`, a bounded loopback
netcat probe can still identify the occupied endpoint. None of those results
grants authority to stop the owner.

## SSH consistency

Each generation records one canonical SSH executable identity and a digest of
the complete normalized `ssh -G` result. Direct retries and autossh children
pass through a generation-owned gate that rechecks both immediately before
exec. Drift refuses the retry until an explicit forced start; it does not churn
a live connection.

SSH multiplex reuse, tunnel devices, local commands, remote commands, and
ambient forwards are disabled or rejected so the manifest describes every
managed resource. Values are always argv elements—no shell command string is
constructed.

## Eternal Terminal consistency

The stock ET built-in records one canonical ET 7.0.0 executable identity and
SHA-256 digest. A generation-owned gate rechecks both immediately before exec,
forces a fixed safe `TERM`, disables telemetry, and points generic temporary
state into a private directory. ET logs remain visible in its tmux pane.

ET parses SSH configuration itself and later invokes a command named `ssh`.
Preparation therefore rejects ambient configuration that ET would turn into
undeclared forwarding, environment, agent, remote-command, or proxy behavior.
The plain effective SSH view is bound before launch and checked both before ET
exec and again after ET has parsed it. A private PATH shim then passes ET's argv
unchanged to a second gate for the exact trusted OpenSSH executable with
forwarding, local commands, multiplexing, agent forwarding, and tunnel devices
disabled. Proxy routing is not guessed into this model; it is rejected until a
future implementation can authenticate ET's two separate jump-host calls.

## ettun consistency

The ettun built-in records canonical identities and SHA-256 digests for the
public `ettun` engine and its selected transport: stock ET 7.0.0 by default or
an explicitly declared adapter. An adapter must pass its noninteractive nested
dependency validation during transaction preparation. Preparation copies the
engine and any adapter into generation-owned executable snapshots only after
before/after identity and digest checks. The launch gate reauthenticates the
installed sources immediately before launch, then executes the engine snapshot
and exports only the adapter snapshot. Engine worker re-execs and repeated
adapter calls therefore stay on the same reviewed bytes for the generation.
The gate also removes ambient transport and client-identity overrides that are
absent from the manifest and pins temporary state beneath the generation. Only
a loopback-bound local forward is accepted by this built-in.

The default stock-ET route never exposes the raw ET executable to ettun. It
exports a generation-owned wrapper that accepts only ettun's reviewed ET 7.0.0
argv shape, fixes `TERM`, disables telemetry, uses private temporary state, and
places the same authenticated SSH shim used by the direct ET driver first on
`PATH`. Ambient SSH forwarding, remote commands, agents, environment, and
proxy routing are rejected before ET starts and rechecked at its bootstrap.

## Crash behavior

Recovery operates on an entire authenticated generation. A verified incomplete
pending generation can be rolled back; an active generation remains
authoritative unless its authenticated control record already committed stop
intent. Committed `stopping` cleanup resumes before replacement dependencies
are inspected. Unverifiable remnants are reported and retained rather than
adopted or deleted. This conservative choice favors not signalling an unrelated
process over automatic cleanup in ambiguous states.

Shell cannot guarantee cleanup after SIGKILL, host loss, or power failure.
Those limits are documented rather than hidden behind unsafe PID guesses.
