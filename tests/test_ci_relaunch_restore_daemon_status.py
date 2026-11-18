#!/usr/bin/env python3
"""The relaunch check reads the daemon's `acpmux status --json` whole.

`acpmux status --json` prints one indented JSON document over many lines. The first version of
scripts/ci/relaunch_restore_check.py's `daemon_status` parsed only the last line (`}`), so every daemon phase and
the session count in its phase table came out blank (cmux#45697 review F1). `status_json` reads the document from its
first `{` line on, past a notice line before it.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import relaunch_restore_check as check  # noqa: E402

STATUS = {
    "ok": True,
    "value": {
        "sessions": 3,
        "gauges": {"startup": {"bornEpochMs": 1795000000000, "phases": [{"name": "socket ready", "atMs": 5}]}},
    },
}


class StatusJson(unittest.TestCase):
    def test_an_indented_answer_is_read_whole(self) -> None:
        text = json.dumps(STATUS, indent=2) + "\n"
        self.assertEqual(text.strip().splitlines()[-1], "}")
        self.assertEqual(check.status_json(text), STATUS)
        self.assertEqual(check.unwrap(check.status_json(text))["sessions"], 3)

    def test_a_notice_line_before_the_answer_is_skipped(self) -> None:
        text = "acpmux: a newer build is installed\n" + json.dumps(STATUS, indent=2)
        self.assertEqual(check.status_json(text), STATUS)

    def test_a_one_line_answer_still_reads(self) -> None:
        self.assertEqual(check.status_json(json.dumps(STATUS)), STATUS)

    def test_no_answer_is_none(self) -> None:
        for text in ("", "\n", "not json\n", "{ broken\n", "[1, 2]\n"):
            with self.subTest(text=text):
                self.assertIsNone(check.status_json(text))


class AppDaemonHomes(unittest.TestCase):
    """Only the daemon started from this app's bundle is read or stopped (cmux#45697 review, second pass, F2): with
    several builds in one HOME, the first pid file found could be another build's daemon."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.app = root / "cmux NIGHTLY.app"
        self.other_app = root / "cmux DEV other.app"
        self.procs: list[subprocess.Popen] = []

    def tearDown(self) -> None:
        for proc in self.procs:
            proc.kill()
            proc.wait(timeout=5)
        self.tmp.cleanup()

    def daemon(self, app: Path, acp_home: Path) -> int:
        """A stand-in daemon: a copy of `sleep` inside `app`'s bin, running, with its pid in `acp_home`."""
        exe = app / "Contents" / "Resources" / "bin" / "acpmux"
        exe.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(shutil.which("sleep"), exe)
        proc = subprocess.Popen([str(exe), "60"], start_new_session=True)
        self.procs.append(proc)
        acp_home.mkdir(parents=True, exist_ok=True)
        (acp_home / "daemon.pid").write_text(f"{proc.pid}\n")
        return proc.pid

    def test_another_builds_daemon_in_the_same_home_is_skipped(self) -> None:
        mine = self.home / ".acpmux"
        theirs = self.home / ".acpmux" / "builds" / "other-key"
        self.daemon(self.other_app, theirs)
        self.daemon(self.app, mine)
        inst = check.Instance("/nonexistent.sock", str(self.app), str(self.home))
        self.assertEqual(check.daemon_homes(str(self.home)), [mine, theirs])
        self.assertEqual(check.app_daemon_homes(inst), [mine])

    def test_a_stale_pid_file_is_skipped(self) -> None:
        stale = self.home / ".acpmux"
        stale.mkdir(parents=True)
        (stale / "daemon.pid").write_text("999999999\n")
        inst = check.Instance("/nonexistent.sock", str(self.app), str(self.home))
        self.assertEqual(check.app_daemon_homes(inst), [])

    def test_runs_from_needs_the_bundle_itself(self) -> None:
        self.assertTrue(check.runs_from(f"{self.app}/Contents/Resources/bin/acpmux", str(self.app)))
        self.assertFalse(check.runs_from(f"{self.app} copy/Contents/Resources/bin/acpmux", str(self.app)))
        self.assertFalse(check.runs_from(None, str(self.app)))


if __name__ == "__main__":
    unittest.main()
