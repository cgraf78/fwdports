# Public command

`fwdports` is the only installed entry point. It resolves its implementation
relative to the checkout selected by the installer-created symlink; the
checkout-owned command and libraries are a single versioned unit.

The command intentionally stays thin. Parsing, runtime ownership, drivers,
health policy, and tmux operations live under `lib/fwdports`, where tests can
exercise them without spawning the CLI through a shell command string.
