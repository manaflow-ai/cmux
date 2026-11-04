#!/usr/bin/env python3
"""typing/echo.py on a real PTY: it echoes each key, keeps its records in memory (no log write between reads), and
writes them with an end record at Ctrl-D, SIGTERM, SIGHUP and when the terminal goes away.

    python3 scripts/journeys/typing/test_echo.py

Off macOS (no CLOCK_UPTIME_RAW) the program runs with CLOCK_MONOTONIC in its place; the clock is not under test.
"""
import json
import os
import pty
import select
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path

ECHO = Path(__file__).resolve().parent / "echo.py"
WRAP = ("import runpy, sys, time; time.CLOCK_UPTIME_RAW = getattr(time, 'CLOCK_UPTIME_RAW', time.CLOCK_MONOTONIC); "
        "sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')")


class EchoProgram(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log = Path(self.tmp.name) / "echo.jsonl"
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execv(sys.executable, [sys.executable, "-I", "-c", WRAP, str(ECHO), str(self.log)])
        self.until(lambda: self.log.exists() and '"ready"' in self.log.read_text(), "the ready line")

    def tearDown(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        os.close(self.fd)
        self.tmp.cleanup()

    def until(self, ok, what, seconds=10.0):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if ok():
                return
            time.sleep(0.02)
        self.fail(f"no {what} within {seconds} s")

    def type(self, data, expect):
        """Writes DATA to the terminal and reads its echo until EXPECT has come."""
        os.write(self.fd, data)
        got, end = b"", time.monotonic() + 10
        while expect not in got and time.monotonic() < end:
            if select.select([self.fd], [], [], 0.1)[0]:
                got += os.read(self.fd, 4096)
        self.assertIn(expect, got)

    def lines(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()]

    def ended(self):
        return any(r.get("end") for r in self.lines())

    def reads(self):
        return b"".join(bytes.fromhex(r["bytes"]) for r in self.lines() if "bytes" in r)

    def test_echoes_without_a_log_write_and_writes_all_at_sigterm(self):
        self.type(b"a", b"a")
        self.type(b"\x7f", b"\b \b")
        self.type(b"\x03", b"^C\r\n")
        self.type(b"\x1b[200~hi\x1b[201~", b"hi")
        self.assertEqual([r for r in self.lines() if "bytes" in r], [], "a record was written while it ran")
        os.kill(self.pid, signal.SIGTERM)
        self.until(self.ended, "end record")
        end = self.lines()[-1]
        self.assertEqual(end["why"], f"signal {int(signal.SIGTERM)}")
        self.assertEqual(self.reads(), b"a\x7f\x03\x1b[200~hi\x1b[201~")
        self.assertEqual(end["reads"], len([r for r in self.lines() if "bytes" in r]))
        times = [r["t"] for r in self.lines() if "bytes" in r]
        self.assertEqual(times, sorted(times))
        self.assertEqual(os.waitpid(self.pid, 0)[1], 0)

    def test_ctrl_d_keeps_the_bytes_before_it_only(self):
        self.type(b"x", b"x")
        os.write(self.fd, b"y\x04z")
        self.until(self.ended, "end record")
        self.assertEqual(self.lines()[-1]["why"], "ctrl-d")
        self.assertEqual(self.reads(), b"xy")

    def test_sighup_writes_the_records(self):
        self.type(b"q", b"q")
        os.kill(self.pid, signal.SIGHUP)
        self.until(self.ended, "end record")
        self.assertEqual(self.lines()[-1]["why"], f"signal {int(signal.SIGHUP)}")
        self.assertEqual(self.reads(), b"q")


if __name__ == "__main__":
    unittest.main()
