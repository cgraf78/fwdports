#!/usr/bin/env python3
"""Select one POSIX process session from a validated Darwin ps snapshot."""

from __future__ import annotations

import argparse
import errno
import os
import select
import signal
import sys
import time
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

EMPTY = 1
ERROR = 2


class ScanError(Exception):
    """The supplied snapshot could not establish a complete session view."""


@dataclass(frozen=True, order=True)
class ProcessRecord:
    """One strict process row supplied by the fwdports ps adapter."""

    pid: int
    pgid: int
    tty: str
    state: str

    def render(self) -> str:
        """Render the record for the shell-side strict parser."""

        return f"{self.pid}\t{self.pgid}\t{self.tty}\t{self.state}"


def _nonnegative_decimal(value: str, field: str) -> int:
    if not value.isdecimal():
        raise ScanError(f"invalid {field}")
    number = int(value, 10)
    if number < 0:
        raise ScanError(f"invalid {field}")
    return number


def _positive_decimal(value: str, field: str) -> int:
    number = _nonnegative_decimal(value, field)
    if number == 0:
        raise ScanError(f"invalid {field}")
    return number


def parse_snapshot(lines: Iterable[str], real_uid: int) -> list[ProcessRecord]:
    """Validate every ps row, then retain unique rows owned by real_uid."""

    records: dict[int, ProcessRecord] = {}
    for raw_line in lines:
        fields = raw_line.split()
        if len(fields) != 5:
            raise ScanError("malformed ps row")
        uid_text, pid_text, pgid_text, tty, state = fields
        uid = _nonnegative_decimal(uid_text, "uid")
        pid = _nonnegative_decimal(pid_text, "pid")
        pgid = _nonnegative_decimal(pgid_text, "pgid")
        if not tty or not state:
            raise ScanError("incomplete ps row")
        # Darwin can expose kernel PID 0. It is not a user process, and
        # getsid(0) means "the caller" rather than "PID 0".
        if pid == 0:
            continue
        if uid != real_uid:
            continue
        if pgid == 0:
            raise ScanError("invalid pgid")
        record = ProcessRecord(pid=pid, pgid=pgid, tty=tty, state=state)
        previous = records.get(pid)
        if previous is not None and previous != record:
            raise ScanError("conflicting pid rows")
        records[pid] = record
    return sorted(records.values())


def select_session(records: Iterable[ProcessRecord], wanted_sid: int) -> list[ProcessRecord]:
    """Return records whose kernel session ID equals wanted_sid."""

    selected: list[ProcessRecord] = []
    for record in records:
        try:
            sid = os.getsid(record.pid)
        except ProcessLookupError:
            continue
        except OSError as error:
            if error.errno == errno.ESRCH:
                continue
            raise ScanError("getsid failed") from error
        if sid == wanted_sid:
            selected.append(record)
    return selected


def _close_quietly(descriptor: int) -> None:
    """Close one owned descriptor, tolerating an already-closed edge."""

    if descriptor < 0:
        return
    try:
        os.close(descriptor)
    except OSError:
        pass


def _run_probe_child(ready_write: int, lifetime_read: int) -> None:
    """Own a new session only while the probing parent keeps its pipe open."""

    try:
        os.setsid()
        null_fd = os.open(os.devnull, os.O_RDWR)
        for descriptor in (0, 1, 2):
            os.dup2(null_fd, descriptor)
        if null_fd > 2:
            os.close(null_fd)
        os.write(ready_write, b"1")
        os.close(ready_write)
        ready_write = -1
        while os.read(lifetime_read, 4096):
            pass
        os._exit(0)
    except OSError:
        os._exit(ERROR)
    finally:
        _close_quietly(ready_write)
        _close_quietly(lifetime_read)


def start_probe_child() -> tuple[int, int, int]:
    """Start a probe child and return PID, ready reader, and liveness writer."""

    ready_read, ready_write = os.pipe()
    lifetime_read, lifetime_write = os.pipe()
    try:
        child_pid = os.fork()
    except OSError:
        for descriptor in (
            ready_read,
            ready_write,
            lifetime_read,
            lifetime_write,
        ):
            _close_quietly(descriptor)
        raise
    if child_pid == 0:
        os.close(ready_read)
        os.close(lifetime_write)
        _run_probe_child(ready_write, lifetime_read)
        os._exit(ERROR)

    os.close(ready_write)
    os.close(lifetime_read)
    return child_pid, ready_read, lifetime_write


def _reap_probe_child(child_pid: int) -> bool:
    """Reap a cooperative probe child, with a bounded kill fallback."""

    deadline = time.monotonic() + 0.5
    while time.monotonic() < deadline:
        try:
            waited_pid, _ = os.waitpid(child_pid, os.WNOHANG)
        except ChildProcessError:
            return False
        if waited_pid == child_pid:
            return True
        time.sleep(0.01)
    try:
        os.kill(child_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        waited_pid, _ = os.waitpid(child_pid, 0)
    except ChildProcessError:
        return False
    return waited_pid == child_pid


def probe() -> bool:
    """Prove getsid can identify a child-created session and reap that child."""

    ready_read = -1
    lifetime_write = -1
    child_pid = -1
    success = False
    reaped = False
    try:
        if os.getsid(0) <= 0:
            raise ScanError("invalid caller session")
        child_pid, ready_read, lifetime_write = start_probe_child()
        readable, _, _ = select.select([ready_read], [], [], 2.0)
        if readable and os.read(ready_read, 1) == b"1":
            success = os.getsid(child_pid) == child_pid
    except (OSError, ScanError):
        success = False
    finally:
        _close_quietly(ready_read)
        # The child blocks only while this descriptor remains open. Kernel
        # descriptor teardown therefore also handles an abrupt TERM/HUP of
        # the parent, when Python's finally block cannot run.
        _close_quietly(lifetime_write)
        if child_pid > 0:
            reaped = _reap_probe_child(child_pid)
    return success and reaped


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    """Parse the intentionally small internal command surface."""

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("sid", nargs="?")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    """Run a capability probe or select matching rows from standard input."""

    try:
        args = parse_args(argv)
        if args.probe:
            if args.sid is not None:
                return ERROR
            return 0 if probe() else ERROR
        if args.sid is None:
            return ERROR
        wanted_sid = _positive_decimal(args.sid, "sid")
        records = parse_snapshot(sys.stdin, os.getuid())
        selected = select_session(records, wanted_sid)
    except (ScanError, OSError, ValueError):
        return ERROR

    if not selected:
        return EMPTY
    output = "\n".join(record.render() for record in selected)
    sys.stdout.write(f"{output}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
