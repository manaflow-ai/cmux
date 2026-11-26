#!/usr/bin/env python3
"""A rivals restart measurement requires a successful cache purge for every app."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/perf-bench"))
import rivals


class Restart(unittest.TestCase):
    def test_initial_purge_probe_tolerates_unavailable_purge(self):
        for error in (subprocess.CalledProcessError(1, "purge"),
                      subprocess.TimeoutExpired("purge", 180), FileNotFoundError("sudo")):
            with self.subTest(error=type(error).__name__), \
                    patch.object(rivals.subprocess, "run", side_effect=error):
                self.assertFalse(rivals.can_purge())
        with patch.object(rivals.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            self.assertTrue(rivals.can_purge())

    def test_purge_outcome_controls_restart_but_preserves_warm_passes(self):
        for name in ("cmux", "zed", "chrome", "safari"):
            for outcome in ("success", "disabled", "failure", "timeout", "missing"):
                with self.subTest(app=name, purge=outcome), tempfile.TemporaryDirectory() as root:
                    run = rivals.Run.__new__(rivals.Run)
                    run.args = SimpleNamespace(cache=root, warm=3, tabs=0, quarantined=False)
                    run.work = root
                    run.signed_in = {}
                    run.launch = Mock(return_value=True)
                    run.soak = Mock()
                    run.record = Mock()
                    app = Mock(name=name)
                    app.name = name
                    app.source = os.path.join(root, "App.app")

                    def command(argv, **kwargs):
                        if argv[0] == "cp":
                            return subprocess.CompletedProcess(argv, 0)
                        self.assertEqual(argv, ["sudo", "-n", "/usr/sbin/purge"])
                        if outcome == "timeout":
                            raise subprocess.TimeoutExpired(argv, 180)
                        if outcome == "missing":
                            raise FileNotFoundError("purge unavailable")
                        code = 1 if outcome == "failure" else 0
                        if code and kwargs.get("check"):
                            raise subprocess.CalledProcessError(code, argv, stderr=b"purge refused")
                        return subprocess.CompletedProcess(argv, code, stderr=b"purge refused" if code else b"")

                    with patch.object(rivals.subprocess, "run", side_effect=command) as commands, \
                            patch.object(rivals.time, "sleep"), \
                            patch.object(rivals, "make_writable_and_remove"):
                        run.session(app, 2, outcome != "disabled")

                    kinds = [call.args[2] for call in run.launch.call_args_list]
                    expected = ["fresh"] + (["restart"] if outcome == "success" else []) + ["warm"] * 3
                    self.assertEqual(kinds, expected)
                    run.soak.assert_called_once_with(app, 2)
                    nulls = {call.args[2]: call for call in run.record.call_args_list}
                    if outcome == "success":
                        self.assertFalse(nulls)
                    else:
                        for row in ("restart-window", "restart-cpu", "restart-memory-peak"):
                            self.assertIsNone(nulls[row].args[3])
                            self.assertIn("purge", nulls[row].kwargs["note"])
                    purges = [call for call in commands.call_args_list if call.args[0][0] == "sudo"]
                    self.assertEqual(len(purges), int(outcome != "disabled"))


if __name__ == "__main__":
    unittest.main()
