#!/usr/bin/env python3
"""`cmux wait-for` keeps its signal and lock files in a private per-user directory.

A world-writable `/tmp` path lets another user pre-create a lock (blocking the
channel forever) or plant a symlink the CLI writes through, so `-L`/`-U` locks
must live beside the signals, not in `/tmp`.

Compiles the CLI's wait-for signal owner with a small driver. No app, socket
or full CLI build.
"""

from __future__ import annotations

import os
from pathlib import Path
import select
import stat
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class TmuxWaitForSignalPrivateDirectory(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-wait-for-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "wait-for-fixture"
        build = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5",
            "-module-cache-path", str(Path(cls.temp.name) / "cache"),
            str(ROOT / "CLI/CLIError.swift"), str(ROOT / "CLI/TmuxWaitForSignal.swift"),
            str(ROOT / "tests/fixtures/TmuxWaitForSignalFixture.swift"), "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=300)
        if build.returncode:
            raise RuntimeError(build.stderr)

    def setUp(self) -> None:
        self.name = f"cmux-test-{uuid.uuid4().hex}"
        self.path = Path(self.run_fixture("path").stdout.strip())
        self.addCleanup(self.remove_signal_path)

    def run_fixture(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        command = arguments[0]
        return subprocess.run([str(self.binary), command, self.name, *arguments[1:]],
                              capture_output=True, text=True, timeout=30)

    def remove_signal_path(self) -> None:
        for path in (self.path, self.lock_path()):
            try:
                path.unlink()
            except FileNotFoundError:
                pass

    def lock_path(self, name: str | None = None) -> Path:
        return Path(subprocess.run(
            [str(self.binary), "lockpath", name or self.name], capture_output=True, text=True, check=True
        ).stdout.strip())

    def prepare_directory(self) -> None:
        # Signal and consume once so the signal directory exists.
        self.assertEqual(self.run_fixture("signal").stdout.strip(), "OK")
        self.assertEqual(self.run_fixture("wait", "0").stdout.strip(), "OK")

    def assert_private_directory(self, directory: Path) -> None:
        info = os.lstat(directory)
        self.assertTrue(stat.S_ISDIR(info.st_mode), f"{directory} is not a real directory")
        self.assertEqual(info.st_uid, os.geteuid())
        self.assertEqual(stat.S_IMODE(info.st_mode) & 0o077, 0,
                         f"{directory} mode is {oct(stat.S_IMODE(info.st_mode))}")

    def test_signal_lands_in_private_directory(self) -> None:
        self.assertEqual(self.run_fixture("signal").stdout.strip(), "OK")
        self.assert_private_directory(self.path.parent)
        info = os.lstat(self.path)
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(info.st_uid, os.geteuid())

    def test_signal_then_wait_consumes_it(self) -> None:
        self.assertEqual(self.run_fixture("signal").stdout.strip(), "OK")
        self.assertEqual(self.run_fixture("wait", "0").stdout.strip(), "OK")
        self.assertFalse(os.path.lexists(self.path))
        self.assertEqual(self.run_fixture("wait", "0").stdout.strip(), "timeout")

    def test_wait_wakes_on_later_signal(self) -> None:
        self.prepare_directory()
        # The waiter's own timeout is far past communicate()'s, so its OK can
        # only come from the signal, not from the wait running out.
        waiter = subprocess.Popen([str(self.binary), "wait", self.name, "600"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            # The waiter reports once its watch is armed and it has found no signal.
            # Bounded: a waiter that stays alive without announcing must fail
            # fast, not hang the lane. The fixture writes the whole line at once.
            ready, _, _ = select.select([waiter.stderr], [], [], 30)
            self.assertTrue(ready, "wait waiter never announced `watching`")
            self.assertEqual(waiter.stderr.readline().strip(), "watching")
            self.assertFalse(os.path.lexists(self.path))
            self.assertEqual(self.run_fixture("signal").stdout.strip(), "OK")
            out, err = waiter.communicate(timeout=60)
        finally:
            if waiter.poll() is None:
                waiter.kill()
                waiter.communicate()
        self.assertEqual(out.strip(), "OK", err)
        self.assertFalse(os.path.lexists(self.path))

    def test_wait_does_not_accept_a_symlink(self) -> None:
        self.prepare_directory()
        target = Path(self.temp.name) / f"{self.name}-target"
        target.write_text("kept\n")
        os.symlink(target, self.path)
        self.assertEqual(self.run_fixture("wait", "0.3").stdout.strip(), "timeout")
        self.assertEqual(target.read_text(), "kept\n")

    def test_channel_names_have_distinct_signal_files(self) -> None:
        first = f"cmux-test-{uuid.uuid4().hex}/a/b"
        second = first.replace("/", "_")
        first_path = Path(subprocess.run(
            [str(self.binary), "path", first], capture_output=True, text=True, check=True
        ).stdout.strip())
        second_path = Path(subprocess.run(
            [str(self.binary), "path", second], capture_output=True, text=True, check=True
        ).stdout.strip())
        self.assertNotEqual(first_path, second_path)
        self.assertEqual(subprocess.run(
            [str(self.binary), "signal", first], capture_output=True, text=True, check=True
        ).stdout.strip(), "OK")
        self.assertEqual(subprocess.run(
            [str(self.binary), "wait", second, "0"], capture_output=True, text=True, check=True
        ).stdout.strip(), "timeout")
        self.assertEqual(subprocess.run(
            [str(self.binary), "wait", first, "0"], capture_output=True, text=True, check=True
        ).stdout.strip(), "OK")

    def test_signal_does_not_follow_a_symlink(self) -> None:
        self.prepare_directory()
        target = Path(self.temp.name) / f"{self.name}-created"
        os.symlink(target, self.path)
        self.run_fixture("signal")
        self.assertFalse(os.path.lexists(target), "signal wrote through a symlink")

    def test_group_writable_directory_is_not_used(self) -> None:
        self.prepare_directory()
        directory = self.path.parent
        self.assert_private_directory(directory)
        os.chmod(directory, 0o770)
        try:
            self.assertNotEqual(self.run_fixture("signal").returncode, 0)
            self.assertFalse(os.path.lexists(self.path))
            self.assertNotEqual(self.run_fixture("wait", "0").returncode, 0)
        finally:
            os.chmod(directory, 0o700)

    def test_lock_lands_in_private_directory_not_tmp(self) -> None:
        lock_path = self.lock_path()
        self.assertFalse(str(lock_path).startswith("/tmp/"), lock_path)
        self.assertEqual(lock_path.parent, self.path.parent, "lock must sit beside the signals")
        self.assertEqual(self.run_fixture("lock").stdout.strip(), "OK")
        self.assert_private_directory(lock_path.parent)
        info = os.lstat(lock_path)
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(info.st_uid, os.geteuid())

    def test_lock_is_exclusive_until_unlocked(self) -> None:
        self.assertEqual(self.run_fixture("lock").stdout.strip(), "OK")
        self.assertEqual(self.run_fixture("lock", "0.3").stdout.strip(), "timeout")
        self.assertEqual(self.run_fixture("unlock").stdout.strip(), "OK")
        self.assertFalse(os.path.lexists(self.lock_path()))
        self.assertEqual(self.run_fixture("lock", "0").stdout.strip(), "OK")

    def test_unlock_of_unlocked_channel_succeeds(self) -> None:
        self.prepare_directory()
        self.assertEqual(self.run_fixture("unlock").stdout.strip(), "OK")

    def test_lock_waiter_wakes_on_unlock(self) -> None:
        self.assertEqual(self.run_fixture("lock").stdout.strip(), "OK")
        # Far past communicate()'s timeout, so OK can only come from the unlock.
        waiter = subprocess.Popen([str(self.binary), "lock", self.name, "600"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(waiter.stderr.readline().strip(), "watching")
            self.assertEqual(self.run_fixture("unlock").stdout.strip(), "OK")
            out, err = waiter.communicate(timeout=60)
        finally:
            if waiter.poll() is None:
                waiter.kill()
                waiter.communicate()
        self.assertEqual(out.strip(), "OK", err)
        self.assertTrue(os.path.lexists(self.lock_path()), "the woken waiter now holds the lock")

    def test_lock_does_not_follow_a_symlink(self) -> None:
        self.prepare_directory()
        target = Path(self.temp.name) / f"{self.name}-lock-target"
        os.symlink(target, self.lock_path())
        self.assertEqual(self.run_fixture("lock", "0.3").stdout.strip(), "timeout")
        self.assertFalse(os.path.lexists(target), "lock wrote through a symlink")

    def test_channel_names_have_distinct_lock_files(self) -> None:
        first = f"cmux-test-{uuid.uuid4().hex}/a/b"
        second = first.replace("/", "_")
        self.assertNotEqual(self.lock_path(first), self.lock_path(second))
        self.addCleanup(lambda: [self.lock_path(n).unlink(missing_ok=True) for n in (first, second)])
        for name in (first, second):
            self.assertEqual(subprocess.run(
                [str(self.binary), "lock", name, "0"], capture_output=True, text=True, check=True
            ).stdout.strip(), "OK")

    def test_lock_refuses_group_writable_directory(self) -> None:
        self.prepare_directory()
        directory = self.path.parent
        os.chmod(directory, 0o770)
        try:
            self.assertNotEqual(self.run_fixture("lock").returncode, 0)
            self.assertFalse(os.path.lexists(self.lock_path()))
            self.assertNotEqual(self.run_fixture("unlock").returncode, 0)
        finally:
            os.chmod(directory, 0o700)


if __name__ == "__main__":
    unittest.main()
