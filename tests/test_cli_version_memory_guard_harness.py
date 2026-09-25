#!/usr/bin/env python3
"""Tests for the timing harness in tests/test_cli_version_memory_guard.py.

The guard times `cmux --version` on a fresh copy of the CLI. On the owned CI
Macs the first launch of any new executable pays a one-time system check (about
3 s, up to 15 s on a busy host) before main runs, which failed compile
admission in 4 of 61 jobs while the CLI itself answered correctly. These drive
the guard with fake CLIs: a one-time launch cost must not fail it, a CLI that
is slow on every run still must, and a timeout must not wait for the child.
"""

from __future__ import annotations

import importlib.util
import os
import stat
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "test_cli_version_memory_guard.py"


def load_guard():
    spec = importlib.util.spec_from_file_location("cli_version_memory_guard", GUARD)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def fake_cli(directory: str, body: str) -> str:
    path = os.path.join(directory, "cmux")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n" + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


VERSION_REPLY = 'if [ "$1" = "--version" ]; then echo "cmux 9.9.9 (999)"; fi\n'


class GuardHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.guard = load_guard()
        self.scratch = tempfile.TemporaryDirectory(prefix="cmux-guard-harness-")
        self.addCleanup(self.scratch.cleanup)
        patches = [
            unittest.mock.patch.object(self.guard, "JUNK_APP_COUNT", 10),
            unittest.mock.patch.object(self.guard, "TIMEOUT_SECONDS", 2.0),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def run_guard(self, cli: str) -> int:
        with unittest.mock.patch.dict(os.environ, {"CMUX_CLI_BIN": cli}):
            return self.guard.main()

    def test_a_one_time_first_launch_cost_does_not_fail_the_guard(self) -> None:
        # The first launch of any copy pays 3 s, like a system check of a new
        # executable; every later launch answers at once.
        marker = os.path.join(self.scratch.name, "launched")
        cli = fake_cli(
            self.scratch.name,
            f'if [ ! -e "{marker}" ]; then touch "{marker}"; sleep 3; fi\n' + VERSION_REPLY,
        )
        self.assertEqual(self.run_guard(cli), 0)

    def test_a_cli_slow_on_every_run_still_fails(self) -> None:
        cli = fake_cli(self.scratch.name, "sleep 3\n" + VERSION_REPLY)
        self.assertEqual(self.run_guard(cli), 1)

    def test_a_timeout_stops_the_cli_instead_of_waiting_for_it(self) -> None:
        # The CLI records that it ran to completion; the guard must stop it
        # at the timeout rather than wait for that.
        finished = os.path.join(self.scratch.name, "finished")
        cli = fake_cli(self.scratch.name, f'sleep 8\ntouch "{finished}"\n' + VERSION_REPLY)
        result = self.guard.run_with_limits(cli, "--version")
        self.assertTrue(str(result["failure_reason"]).startswith("timeout exceeded"))
        self.assertFalse(os.path.exists(finished), "the timed-out CLI was left to run to completion")


if __name__ == "__main__":
    if sys.platform != "darwin":
        print("SKIP: the guard times the CLI with macOS /usr/bin/time -l")
        raise SystemExit(0)
    unittest.main(verbosity=2)
