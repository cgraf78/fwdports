#!/usr/bin/env bash
# Data-only configuration support lives in this checkout-owned module. Keeping
# it separate from the CLI makes the parser reusable by validation, start, and
# tests without duplicating policy or evaluating configuration as shell code.

# Parser functions are added behind behavior tests in the configuration
# checkpoint. This intentionally empty scaffold exists so the installer can
# already enforce the command/library version-coupling contract.
