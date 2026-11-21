#!/usr/bin/env python3
"""Run a Rust test command and end it when one test runs past its deadline.

    test_deadline.py [--deadline-seconds N] [--slow NAME=SECONDS ...] -- <command...>

libtest has no per-test time limit, so a hung cmux-tui test held its hosted job
until the job timeout and read as "cancelled", with no test named (runs
42712581504 and 42687069230, 2026-11-09). This watchdog reads libtest's own
output, passed through unchanged, and knows when each test started:

- parallel runs print `test NAME has been running for over 60 seconds` once a
  test passes 60 s: the test started 60 s before that line;
- one test at a time (`--test-threads=1`) prints no such notice, but writes
  `test NAME ... ` before the test starts and its result after it ends.

When a test passes its deadline (default 180 s, as the app::tests guard of
#39954; CMUX_TEST_DEADLINE_SECONDS or --deadline-seconds sets it;
CMUX_TEST_DEADLINE_SLOW or --slow NAME=SECONDS gives one test, matched by a
name suffix, its own), it prints a GitHub error naming
the test, ends the whole command (its process group) and exits DEADLINE_EXIT.
Otherwise it exits with the command's own status. Build time has no deadline:
only a test that libtest reports as started is timed.

Both signals date the test's start, so a deadline is met to within one poll
(POLL_SECONDS). Workflows call it through scripts/ci/cargo-test-deadline.sh,
the one place a later move to cargo-nextest replaces.
Test: tests/test_ci_test_deadline.py.

Known limits (deadline-rev on #40523):
- The strip handles escapes only. Plain text that a test writes to fd 1 with
  no newline still hides the next libtest line.
- A signal that arrives between Popen and _forward_cancel still orphans the
  group. The window is very small, but the handlers can be installed before
  Popen (keep a process holder).
"""

from __future__ import annotations

import argparse
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from typing import Iterable

DEFAULT_SECONDS = 180
DEADLINE_EXIT = 124
NOTICE_SECONDS = 60
POLL_SECONDS = 0.5
KILL_GRACE_SECONDS = 10

_NOTICE = re.compile(r"^test (?P<name>\S.*?) has been running for over 60 seconds$")
_RESULT = re.compile(r"^test (?P<name>\S.*?) \.\.\. (?P<result>\S.*)$")
_STARTED = re.compile(r"^test (?P<name>\S.*?) \.\.\. $")
_SUMMARY = re.compile(r"^test result: ")
# cargo starts the next test binary, or the doctests after the last one, only after the last binary exited, so a
# test that binary left open (it crashed mid-test, no result line; cargo goes on under --no-fail-fast) is over. Only
# cargo's own right-aligned lines count (`     Running unittests src/lib.rs (target/debug/deps/a-0123abcd)`,
# `   Doc-tests a`): a test that prints `Running ...` itself must not clear the tests still open.
_NEXT_BINARY = re.compile(r"^ +(?:Running \S.* \([^()]+\)|Doc-tests \S+)$")
# Tests that drive a terminal write escapes to the shared stdout (on macOS `ESC]12;#ffffff BEL ESC[1 q` before
# libtest's own `test NAME ... ok`, proof run 42808325625), so they are stripped before a line is read.
_ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-_]|[\x00-\x08\x0b-\x1f\x7f]")


def _plain(text: str) -> str:
    return _ESCAPES.sub("", text)


class Tracker:
    """Which tests run now, and since when, from libtest output fed in order."""

    def __init__(self, default_seconds: float = DEFAULT_SECONDS, slow: dict[str, float] | None = None) -> None:
        self.default_seconds = default_seconds
        self.slow = dict(slow or {})
        self.running: dict[str, float] = {}
        self.partial = ""

    def limit(self, name: str) -> float:
        for suffix, seconds in self.slow.items():
            if name == suffix or name.endswith("::" + suffix):
                return seconds
        return self.default_seconds

    def feed(self, text: str, *, now: float) -> None:
        self.partial += text
        *lines, self.partial = self.partial.split("\n")
        for line in lines:
            self._line(_plain(line.rstrip("\r")), now)
        started = _STARTED.match(_plain(self.partial))
        if started:
            # libtest wrote `test NAME ... ` and waits for the test (one at a time).
            self.running.setdefault(started.group("name"), now)

    def _line(self, line: str, now: float) -> None:
        if _SUMMARY.match(line) or _NEXT_BINARY.match(line):
            self.running.clear()
            return
        notice = _NOTICE.match(line)
        if notice:
            self.running.setdefault(notice.group("name"), now - NOTICE_SECONDS)
            return
        result = _RESULT.match(line)
        if result:
            self.running.pop(result.group("name"), None)

    def overdue(self, *, now: float) -> tuple[str, int] | None:
        for name, since in sorted(self.running.items(), key=lambda item: item[1]):
            limit = self.limit(name)
            if now - since >= limit:
                return name, int(limit)
        return None


def _reader(fd: int, chunks: "queue.Queue[bytes]") -> None:
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        chunks.put(data)
        if not data:
            return


def _report_threads(pid: int) -> None:
    """Linux: every thread of the process group and the kernel wait it sleeps in (best effort)."""
    if not sys.platform.startswith("linux"):
        return
    try:
        pgid = os.getpgid(pid)
    except OSError:
        return
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", encoding="utf-8") as stat:
                fields = stat.read().rsplit(")", 1)[1].split()
            if int(fields[2]) != pgid:
                continue
            for task in os.listdir(f"/proc/{entry}/task"):
                base = f"/proc/{entry}/task/{task}"
                with open(f"{base}/comm", encoding="utf-8") as comm, open(f"{base}/wchan", encoding="utf-8") as wchan:
                    print(f"  pid {entry} thread {task} {comm.read().strip()!r}: {wchan.read().strip()}",
                          file=sys.stderr)
        except (OSError, IndexError, ValueError):
            continue


def _end(process: subprocess.Popen[bytes]) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            # macOS answers EPERM for a group whose members are all zombies.
            return
        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
            return
        except subprocess.TimeoutExpired:
            continue


def _forward_cancel(process: subprocess.Popen[bytes]) -> list[int]:
    """Pass a job cancel (SIGTERM, SIGINT, SIGHUP) on to the test process group, which runs in its own session
    and so would not get it; returns the signals received, for the exit status."""
    received: list[int] = []
    if os.name == "nt":
        return received

    def forward(signum, _frame) -> None:
        received.append(signum)
        try:
            os.killpg(process.pid, signum)
        except (ProcessLookupError, PermissionError):
            pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, forward)
    return received


def run(command: list[str], tracker: Tracker, *, clock=time.monotonic) -> int:
    """Run `command`, pass its output through, and return its status or DEADLINE_EXIT."""
    kwargs: dict = {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
    else:
        kwargs["start_new_session"] = True
    process = subprocess.Popen(command, **kwargs)
    assert process.stdout is not None
    chunks: "queue.Queue[bytes]" = queue.Queue()
    threading.Thread(target=_reader, args=(process.stdout.fileno(), chunks), daemon=True).start()
    out = sys.stdout.buffer
    cancelled = _forward_cancel(process)
    while True:
        try:
            data = chunks.get(timeout=POLL_SECONDS)
        except queue.Empty:
            data = None
        if data:
            out.write(data)
            out.flush()
            tracker.feed(data.decode("utf-8", errors="replace"), now=clock())
        elif data == b"":
            status = process.wait()
            return 128 + cancelled[0] if cancelled else status
        late = tracker.overdue(now=clock())
        if late:
            name, limit = late
            print(f"\n::error title=test deadline::test {name} ran past its {limit} s deadline; ending the test "
                  "run so the job does not wait for its timeout", file=sys.stderr, flush=True)
            _report_threads(process.pid)
            _end(process)
            return DEADLINE_EXIT


def parse_slow(values: Iterable[str]) -> dict[str, float]:
    """NAME=SECONDS items as a name-suffix -> seconds map; a bad item ends the program."""
    slow: dict[str, float] = {}
    for value in values:
        name, separator, seconds = value.rpartition("=")
        if not separator or not name or not seconds.isdigit() or int(seconds) <= 0:
            raise SystemExit(f"test_deadline.py: --slow takes NAME=SECONDS, not {value!r}")
        slow[name] = float(seconds)
    return slow


def env_settings(environ=os.environ) -> tuple[int, dict[str, float]]:
    """The deadline (CMUX_TEST_DEADLINE_SECONDS, default 180) and the slow overrides
    (CMUX_TEST_DEADLINE_SLOW: space-separated NAME=SECONDS) of this job."""
    raw = environ.get("CMUX_TEST_DEADLINE_SECONDS", "")
    seconds = int(raw) if raw.isdigit() and int(raw) > 0 else DEFAULT_SECONDS
    return seconds, parse_slow(environ.get("CMUX_TEST_DEADLINE_SLOW", "").split())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--deadline-seconds", type=int, default=None)
    parser.add_argument("--slow", action="append", default=[], metavar="NAME=SECONDS")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    seconds, slow = env_settings()
    if args.deadline_seconds is not None:
        if args.deadline_seconds <= 0:
            parser.error("--deadline-seconds must be positive")
        seconds = args.deadline_seconds
    slow.update(parse_slow(args.slow))
    return run(command, Tracker(default_seconds=seconds, slow=slow))


if __name__ == "__main__":
    sys.exit(main())
