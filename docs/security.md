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

Built-in executable parents are checked back to the filesystem root. The one
exception is a structurally recognized `$PREFIX` in an actual Termux runtime,
where Android's app sandbox protects ancestors using policy that ordinary Unix
mode bits cannot represent; the prefix node and every descendant are still
validated. Both Bash's Android `OSTYPE` and the app-data prefix shape must
match; a generic caller-supplied `PREFIX` grants no such exception.

State and runtime roots are mode 0700, generated files use a restrictive
umask, and manifests/control records are mode 0600. Atomic same-directory
renames publish files only after complete content is available.

## Process ownership

Core never kills by program name, argv substring, port number, `pgrep -f`, or a
bare recorded PID. A generation nonce, tmux relationship, PID start identity,
tty, session, and process group must all still agree before TERM is sent. KILL
is used only after a bounded condition wait and a second ownership check. A
missing leader, foreign member, or incomplete record fails closed.

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

## Crash behavior

Recovery operates on an entire authenticated generation. A verified incomplete
pending generation can be rolled back; an active generation remains
authoritative. Unverifiable remnants are reported and retained rather than
adopted or deleted. This conservative choice favors not signalling an unrelated
process over automatic cleanup in ambiguous states.

Shell cannot guarantee cleanup after SIGKILL, host loss, or power failure.
Those limits are documented rather than hidden behind unsafe PID guesses.
