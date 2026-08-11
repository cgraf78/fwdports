# Security and trust model

`fwdports` narrows lifecycle authority; it is not a sandbox for code the user
chooses to install. User SSH configuration and external driver executables are
trusted same-user inputs. Profile data is non-executable but can intentionally
expose network ports, so it still receives strict syntax and path validation.
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

## Crash behavior

Recovery operates on an entire authenticated generation. A verified incomplete
pending generation can be rolled back; an active generation remains
authoritative. Unverifiable remnants are reported and retained rather than
adopted or deleted. This conservative choice favors not signalling an unrelated
process over automatic cleanup in ambiguous states.

Shell cannot guarantee cleanup after SIGKILL, host loss, or power failure.
Those limits are documented rather than hidden behind unsafe PID guesses.
