"""The servers row: a refused or unapproved leg never reads as a pass, and the sample server it starts is the
Hello Python sample retargeted to the customize app."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("servers_row_driver", Path(__file__).resolve().parent.parent / "ext-rows-nightly.py")
driver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = driver
spec.loader.exec_module(driver)


class RunRowsUnprovenTests(unittest.TestCase):
    def run_row(self, result):
        with patch.dict(driver.ROWS, {"servers": (lambda ctx: dict(result), "#49223")}), \
                contextlib.redirect_stdout(io.StringIO()):
            return driver.run_rows(SimpleNamespace(control=None), ["servers"])["servers"]

    def test_unproven_with_passing_checks_is_neither_passed_nor_failed(self):
        row = self.run_row({"checks": {"installed": True}, "unproven": "needs the person's approval"})
        self.assertIsNone(row["ok"])
        self.assertIn("unproven", row)

    def test_unproven_cannot_hide_a_failed_check(self):
        row = self.run_row({"checks": {"installed": True, "no_credential_refused": False}, "unproven": "x"})
        self.assertIs(row["ok"], False)

    def test_served_row_passes_only_with_every_check(self):
        self.assertIs(self.run_row({"checks": {"served_with_credential": True}})["ok"], True)
        self.assertIs(self.run_row({"checks": {"served_with_credential": False}})["ok"], False)


class FakeDaemon:
    """A socket that answers `apps-server-attach` with `reply` and records the frame."""

    def __init__(self, path: str, reply: dict):
        self.frames: list[dict] = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(4)
        self.reply = reply
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn:
                line = conn.makefile("r").readline()
                frame = json.loads(line)
                self.frames.append(frame)
                conn.sendall((json.dumps({"id": frame["id"], **self.reply}) + "\n").encode())


class ServerCopyTests(unittest.TestCase):
    def test_retargeted_sample_attaches_as_the_customize_app_and_reports_refusal(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            ctx = SimpleNamespace(work=root, daemon=str(root / "d.sock"))
            script = driver.server_copy(ctx)
            text = script.read_text()
            self.assertIn('APP = "local/customize"', text)
            self.assertIn('FAMILY = "local.customize"', text)
            daemon = FakeDaemon(ctx.daemon, {"ok": False, "error_code": "apps.server_credential",
                                             "error": "no credential"})
            proc, said = driver.start_server(ctx, script, "")
            self.assertEqual(driver.stop(proc), 1)
            self.assertIn("refused: apps.server_credential", said)
            self.assertEqual(daemon.frames[0]["cmd"], "apps-server-attach")
            self.assertEqual(daemon.frames[0]["app"], "local/customize")
            self.assertEqual(daemon.frames[0]["credential"], "")
            daemon.sock.close()


if __name__ == "__main__":
    unittest.main()
