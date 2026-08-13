# Examples

These files are copyable public contracts, not pseudocode. The test suite
loads `tunnels.conf` with the production parser and executes the example
driver's non-lifetime ABI operations directly, so interface changes cannot
leave the examples silently stale.

All endpoints use IANA-reserved example names or loopback addresses. Replace
the host, ports, and labels with your own values after copying the file to
`${XDG_CONFIG_HOME:-$HOME/.config}/fwdports/tunnels.conf`.

The `ssh-default` profile demonstrates the default driver. `ssh-resilient`
selects autossh explicitly; installing autossh never changes another profile's
driver. `et-direct` uses the stock Eternal Terminal 7.0.0 built-in with one local
and one remote forward; its local endpoint has the required matching health
check. `ettun-relay` demonstrates one loopback-only local endpoint whose remote
destination is reached through the public ettun relay engine.
`executable-driver` demonstrates the fixed single-file extension protocol.
Real drivers are trusted local programs and belong in
`${XDG_CONFIG_HOME:-$HOME/.config}/fwdports/drivers.d/` with mode 0700.
