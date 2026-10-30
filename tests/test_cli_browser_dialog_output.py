#!/usr/bin/env python3
"""`cmux browser` prints a page's dialog safely, with a command that answers it.

The dialog message comes from the page, so an escape sequence or a line break
in it must not reach the terminal. The printed command has to name the surface,
because `browser dialog accept` parses `dialog` as the surface. Each case runs
the real CLI against a fake socket.
"""

from __future__ import annotations

import json
import socketserver
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from fake_socket_env import cli_environment, unwrap_capability


SURFACE = "11111111-1111-4111-8111-111111111111"
HOSTILE = "ok?\x1b]0;retitled\x07\r\nforged line "
CLEAN = "ok?]0;retitledforged line"
EXPECTED = f'dialog: confirm "{CLEAN}" (cmux browser {SURFACE} dialog accept|dismiss)'
DIALOG = {"type": "confirm", "message": HOSTILE, "default_text": None}


class Replier(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            response = {"id": request.get("id"), **self.server.reply}  # type: ignore[attr-defined]
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class BrowserDialogOutputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-dialog-out-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.socket_path = str(Path(self.temp.name) / "s")
        self.server = Server(self.socket_path, Replier)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.cli = str(resolve_cmux_cli())

    def click(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.cli, "--socket", self.socket_path, "browser", SURFACE, "click", "#btn"],
            env=cli_environment(AppleLanguages="(en)"), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )

    def test_action_that_opens_a_dialog_prints_it_on_one_clean_line(self) -> None:
        self.server.reply = {  # type: ignore[attr-defined]
            "ok": True,
            "result": {"surface_id": SURFACE, "action": "click", "attempts": 1, "dialog": DIALOG},
        }
        result = self.click()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["OK", EXPECTED])

    def test_dialog_pending_error_prints_the_dialog_and_the_command(self) -> None:
        self.server.reply = {  # type: ignore[attr-defined]
            "ok": False,
            "error": {
                "code": "dialog_pending",
                "message": "A dialog is waiting for browser.dialog.accept or browser.dialog.dismiss",
                "data": {"action": "click", "selector": "#btn", "dialog": DIALOG},
            },
        }
        result = self.click()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dialog_pending: A dialog is waiting", result.stderr)
        self.assertIn(EXPECTED, result.stderr.splitlines())
        self.assertNotIn("\x1b", result.stderr)

    def test_other_errors_print_no_dialog_line(self) -> None:
        self.server.reply = {  # type: ignore[attr-defined]
            "ok": False,
            "error": {"code": "js_error", "message": "boom", "data": {"action": "click"}},
        }
        result = self.click()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("js_error: boom", result.stderr)
        self.assertNotIn("dialog:", result.stderr)


if __name__ == "__main__":
    unittest.main()
