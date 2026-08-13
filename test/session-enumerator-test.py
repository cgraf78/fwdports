#!/usr/bin/env python3
"""Exercise the macOS session probe's parent-liveness contract."""

from __future__ import annotations

import importlib.util
import os
import select
import signal
import sys
import time
from types import ModuleType


def load_helper(path: str) -> ModuleType:
    """Load the generation helper without relying on ambient module search."""

    spec = importlib.util.spec_from_file_location("session_enumerator", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load session enumerator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main(argv: list[str]) -> int:
    """Prove a probe child exits when the sole liveness owner is killed."""

    if len(argv) != 1:
        return 2
    helper = load_helper(argv[0])
    child_pid, ready_read, lifetime_write = helper.start_probe_child()
    holder_pid = -1
    try:
        readable, _, _ = select.select([ready_read], [], [], 2.0)
        if not readable or os.read(ready_read, 1) != b"1":
            return 1
        holder_pid = os.fork()
        if holder_pid == 0:
            os.close(ready_read)
            signal.pause()
            os._exit(1)

        os.close(lifetime_write)
        lifetime_write = -1
        os.kill(holder_pid, signal.SIGTERM)
        os.waitpid(holder_pid, 0)
        holder_pid = -1

        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            waited_pid, _ = os.waitpid(child_pid, os.WNOHANG)
            if waited_pid == child_pid:
                child_pid = -1
                return 0
            time.sleep(0.01)
        return 1
    finally:
        for descriptor in (ready_read, lifetime_write):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        for pid in (holder_pid, child_pid):
            if pid > 0:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
