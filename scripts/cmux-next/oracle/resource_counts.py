#!/usr/bin/env python3
"""One process's open descriptors, threads and child processes: invariant I15's reading (p15-oracle-217).

Stdlib only, Python 3.9+, safe under `python3 -I`. The daemon driver (driver_daemon.py) reads its case daemon
after setup and at teardown, the app driver (driver_app.py) the tag's cmux-tui after the case's fixture setup
and after its fixture teardown; invariants.py I15 compares the two readings.

A reading is {"pid", "fds", "threads", "children", "source"}: `source` names where each count came from, so a
violation says what it read. Linux reads procfs (/proc/<pid>/fd, the Threads line of /proc/<pid>/status,
/proc/<pid>/task/*/children); macOS reads `lsof -p` (numbered descriptors only), `ps -M -p` (one line per
thread after the header) and the ppid column of `ps -A`. A process that is gone, or a tool that fails, gives
None: the invariant is then not checked, never passed.

Chrome reference (chromium/src): base/process/process_metrics.h GetOpenFdCount and
base/process/process_iterator.h (children by parent pid) are the counters Chrome's leak checks read; the
browser tests' fd-leak check compares the count before and after a test (base/test/launcher/test_launcher.cc
reads child processes the same way after each test).

Usage:
  resource_counts.py PID         the reading as JSON
  resource_counts.py --selftest  reads this process and one child it starts
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import unittest
from typing import Any, Callable, Dict, List, Optional, Sequence

LINUX_SOURCE = "/proc/<pid>/fd, /proc/<pid>/status Threads, /proc/<pid>/task/*/children"
MAC_SOURCE = "lsof -p <pid> (numbered fds), ps -M -p <pid>, ps -A -o pid,ppid"
TOOL_S = 30.0

Run = Callable[..., subprocess.CompletedProcess]


def _linux(pid: int) -> Optional[Dict[str, Any]]:
    try:
        fds = len(os.listdir(f"/proc/{pid}/fd"))
        with open(f"/proc/{pid}/status", encoding="utf-8") as handle:
            threads = next(int(line.split()[1]) for line in handle if line.startswith("Threads:"))
        children = 0
        for path in glob.glob(f"/proc/{pid}/task/*/children"):
            with open(path, "rb") as handle:
                children += len(handle.read().split())
    except (OSError, StopIteration, ValueError, IndexError):
        return None  # gone, or not ours to read
    return {"pid": pid, "fds": fds, "threads": threads, "children": children, "source": LINUX_SOURCE}


def _tool(run: Run, argv: List[str]) -> Optional[str]:
    try:
        done = run(argv, capture_output=True, text=True, timeout=TOOL_S, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def _mac(pid: int, run: Run) -> Optional[Dict[str, Any]]:
    # -F f prints one `f<descriptor>` line per open file; cwd, txt and mapped files have names, not numbers.
    files = _tool(run, ["lsof", "-nP", "-p", str(pid), "-F", "f"])
    threads = _tool(run, ["ps", "-M", "-p", str(pid)])
    table = _tool(run, ["ps", "-A", "-o", "pid=,ppid="])
    if files is None or threads is None or table is None:
        return None
    fds = sum(1 for line in files.splitlines() if line.startswith("f") and line[1:].isdigit())
    thread_lines = [line for line in threads.splitlines()[1:] if line.strip()]
    children = 0
    for line in table.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == str(pid):
            children += 1
    if not thread_lines:
        return None  # ps found no such process
    return {"pid": pid, "fds": fds, "threads": len(thread_lines), "children": children, "source": MAC_SOURCE}


def read(pid: Optional[int], run: Run = subprocess.run, platform: str = sys.platform) -> Optional[Dict[str, Any]]:
    """The reading of `pid`, or None when it cannot be read."""
    if not isinstance(pid, int) or pid <= 0:
        return None
    return _linux(pid) if platform.startswith("linux") else _mac(pid, run)


class ResourceCountsSelfTest(unittest.TestCase):
    def test_reads_this_process_and_counts_a_child(self) -> None:
        before = read(os.getpid())
        self.assertIsNotNone(before)
        assert before is not None
        self.assertGreaterEqual(before["threads"], 1)
        self.assertGreaterEqual(before["fds"], 3)
        child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        try:
            during = read(os.getpid())
            assert during is not None
            self.assertEqual(during["children"], before["children"] + 1)
            self.assertGreater(during["fds"], before["fds"], "the pipe to the child is open")
        finally:
            child.communicate(b"")
        self.assertEqual(read(os.getpid())["children"], before["children"])  # type: ignore[index]

    def test_a_gone_process_and_a_bad_pid_give_none(self) -> None:
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        self.assertIsNone(read(child.pid))
        self.assertIsNone(read(None))
        self.assertIsNone(read(0))

    def test_the_mac_reading_from_tool_output(self) -> None:
        outputs = {
            "lsof": "p42\nfcwd\nftxt\nf0\nf1\nf2\nf7\n",
            "ps -M": "USER PID TT %CPU STAT PRI STIME UTIME COMMAND\nme 42 ?? 0.0 S 31T 0:00.01 0:00.01 cmux-tui\n"
                     "    42 0.0 S 31T 0:00.00 0:00.00\n    42 0.0 S 31T 0:00.00 0:00.00\n",
            "ps -A": "  1     0\n 42     1\n 50    42\n 51    42\n 60    50\n",
        }

        def run(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess:
            key = "lsof" if argv[0] == "lsof" else f"ps {argv[1]}"
            return subprocess.CompletedProcess(list(argv), 0, outputs[key], "")

        self.assertEqual(read(42, run=run, platform="darwin"),
                         {"pid": 42, "fds": 4, "threads": 3, "children": 2, "source": MAC_SOURCE})

        def failing(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess:
            return subprocess.CompletedProcess(list(argv), 1, "", "no such process")

        self.assertIsNone(read(42, run=failing, platform="darwin"))


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["--selftest"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ResourceCountsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if len(args) != 1 or not args[0].isdigit():
        print(__doc__.rsplit("Usage:", 1)[-1].rstrip(), file=sys.stderr)
        return 2
    reading = read(int(args[0]))
    if reading is None:
        print(f"resource_counts.py: cannot read process {args[0]}", file=sys.stderr)
        return 1
    print(json.dumps(reading, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
