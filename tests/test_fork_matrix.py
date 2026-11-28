#!/usr/bin/env python3
"""The real-agent fork matrix must not report green when it could not test forks."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "cmux-tui/crates/acpmux/scripts/fork_matrix.py"
spec = importlib.util.spec_from_file_location("fork_matrix", SCRIPT)
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class ForkMatrixTests(unittest.TestCase):
    def daemon(self, root, config=None, **kwargs):
        daemon = matrix.Daemon("unused", root / "home", config, {}, **kwargs)
        self.addCleanup(daemon.log.close)
        self.addCleanup(daemon.sock.parent.rmdir)
        return daemon

    def test_peerless_config_remains_a_map_and_keep_peers_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "source.json"
            config.write_text('{"harnesses": {}}')
            daemon = self.daemon(root, config)
            self.assertEqual(json.loads((daemon.home / "config.json").read_text())["peers"], {})
            config.write_text('{"peers": {"other": {"host": "example"}}}')
            daemon = self.daemon(root, config, keep_peers=True)
            self.assertEqual(json.loads((daemon.home / "config.json").read_text()), json.loads(config.read_text()))

    def test_start_requires_status_from_its_live_daemon(self):
        for status in ('{"running": false}', '{}', 'not json', '{"pid": 999}', '{"pid": 42}'):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                daemon = self.daemon(Path(tmp))
                proc = Mock(pid=42)
                proc.poll.return_value = None
                with patch.object(matrix.subprocess, "Popen", return_value=proc), \
                     patch.object(daemon, "run", return_value=subprocess.CompletedProcess([], 0, status, "")), \
                     patch.object(matrix.time, "time", side_effect=[0, 0, 31]), \
                     patch.object(matrix.time, "sleep"):
                    if status == '{"pid": 42}':
                        daemon.start()
                    else:
                        with self.assertRaises(RuntimeError):
                            daemon.start()

    def test_start_reports_early_process_exit_without_waiting(self):
        with tempfile.TemporaryDirectory() as tmp:
            daemon = self.daemon(Path(tmp))
            proc = Mock(pid=42)
            proc.poll.return_value = 1
            with patch.object(matrix.subprocess, "Popen", return_value=proc), \
                 patch.object(daemon, "run", return_value=subprocess.CompletedProcess([], 0, '{"pid": 42}', "")), \
                 patch.object(matrix.time, "sleep") as sleep:
                with self.assertRaisesRegex(RuntimeError, "exited.*1"):
                    daemon.start()
                sleep.assert_not_called()

    def test_copied_config_is_private_even_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "source.json"
            config.write_text(json.dumps({"harnesses": {}, "peers": {"other": {}}}))
            for existing in (False, True):
                with self.subTest(existing=existing):
                    home = root / str(existing)
                    home.mkdir()
                    if existing:
                        (home / "config.json").write_text("{}")
                        (home / "config.json").chmod(0o666)
                    old_umask = os.umask(0)
                    try:
                        daemon = matrix.Daemon("unused", home, config, {})
                    finally:
                        os.umask(old_umask)
                    self.addCleanup(daemon.log.close)
                    self.addCleanup(daemon.sock.parent.rmdir)
                    copied = home / "config.json"
                    self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(json.loads(copied.read_text())["peers"], {})
                    self.assertIn("other", json.loads(config.read_text())["peers"])

    def invoke(self, results, extra=(), start_error=None):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results.jsonl"
            rows = [{"case": "seed", "result": result, "detail": "test"} for result in results]
            argv = [str(SCRIPT), "--harness", "test=fake", "--out", str(out), *extra]
            with patch.object(matrix.sys, "argv", argv), \
                 patch.object(matrix, "Daemon") as daemon, \
                 patch.object(matrix, "Matrix") as cases, \
                 patch.object(matrix.tempfile, "mkdtemp", return_value=tmp), \
                 contextlib.redirect_stdout(io.StringIO()), \
                 contextlib.redirect_stderr(io.StringIO()):
                cases.return_value.run_all.return_value = rows
                daemon.return_value.start.side_effect = start_error
                try:
                    status = matrix.main()
                except SystemExit as exc:
                    status = exc.code
                except RuntimeError:
                    self.assertIsNotNone(start_error)
                    status = 1
                recorded = [json.loads(line) for line in out.read_text().splitlines()] if out.exists() else []
                return status, recorded, daemon

    def test_complete_pass_is_success(self):
        status, rows, _ = self.invoke(["pass", "pass"])
        self.assertEqual(status, 0)
        self.assertEqual(len(rows), 2)

    def test_failure_is_not_hidden_by_later_passes_or_skips(self):
        for results in (["fail"], ["fail", "pass"], ["pass", "fail"], ["fail", "unsupported"]):
            with self.subTest(results=results):
                status, rows, _ = self.invoke(results)
                self.assertEqual(status, 1)
                self.assertEqual([row["result"] for row in rows], results)

    def test_incomplete_and_unknown_results_are_not_success(self):
        for results in ([], ["pass", "unsupported", "n/a"], ["pass", "unknown"]):
            with self.subTest(results=results):
                status, rows, _ = self.invoke(results)
                self.assertEqual(status, 2)
                self.assertEqual([row["result"] for row in rows], results)

    def test_invalid_selection_does_not_start_daemon(self):
        for args in (("--runs", "0"), ("--runs", "-1"), ("--case", "typo")):
            with self.subTest(args=args):
                status, _, daemon = self.invoke([], extra=args)
                self.assertEqual(status, 2)
                daemon.assert_not_called()

    def test_failed_start_still_stops_its_daemon(self):
        status, _, daemon = self.invoke([], start_error=RuntimeError("not ready"))
        self.assertNotEqual(status, 0)
        daemon.return_value.stop.assert_called_once()


if __name__ == "__main__":
    unittest.main()
