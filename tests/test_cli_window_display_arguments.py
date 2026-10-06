#!/usr/bin/env python3
"""`cmux window display` rejects arguments it doesn't accept.

It used to drop every word starting with a dash and use the first word left
as the display name, so `window display 'LG HDR 4K' --typo` still moved
windows, an unquoted `window display LG HDR 4K` moved them to "LG", and a
`--window` after the subcommand was dropped, which moved every main window
instead of the one named. Each case runs the real CLI against a fake socket
that records requests: a rejected command must exit non-zero and send no
window request, and the documented forms must still send theirs.
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


WIN = "11111111-1111-4111-8111-111111111111"


class Recorder(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            result = {"display": params.get("display", ""), "moved": [WIN],
                      "displays": [{"name": "LG HDR 4K", "index": 0, "main": True}]}
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class WindowDisplayArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-window-args-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.socket_path = str(Path(self.temp.name) / "s")
        self.server = Server(self.socket_path, Recorder)
        self.server.calls = []  # type: ignore[attr-defined]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.cli = str(resolve_cmux_cli())

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        self.server.calls.clear()  # type: ignore[attr-defined]
        return subprocess.run(
            [self.cli, "--socket", self.socket_path, *args],
            env=cli_environment(AppleLanguages="(en)"), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )

    def requests(self) -> list[tuple[str, dict]]:
        return [call for call in self.server.calls  # type: ignore[attr-defined]
                if call[0] in ("window.display", "window.displays")]

    def assert_rejected(self, args: list[str], message: str) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, f"{args} should fail:\n{output}")
            self.assertIn(message, output, f"{args}:\n{output}")
            self.assertEqual(self.requests(), [], f"{args} sent a request:\n{output}")

    def assert_sends(self, args: list[str], method: str, expected: dict) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, f"{args}:\n{output}")
            sent = self.requests()
            self.assertEqual([m for m, _ in sent], [method], f"{args}:\n{output}")
            for key, value in expected.items():
                self.assertEqual(sent[0][1].get(key), value, f"{args} {key}:\n{sent}")

    def test_unknown_options_are_rejected(self) -> None:
        for args, option in (
            (["window", "display", "LG HDR 4K", "--typo"], "--typo"),
            (["window", "display", "--dispay", "LG HDR 4K"], "--dispay"),
            (["window", "display", "LG HDR 4K", "-x"], "-x"),
            (["window", "display", "--list", "--typo"], "--typo"),
            (["window", "displays", "--typo"], "--typo"),
        ):
            self.assert_rejected(args, f"unknown option {option}")

    def test_extra_arguments_are_rejected(self) -> None:
        for args, stray in (
            (["window", "display", "LG", "HDR", "4K"], "HDR"),
            (["window", "display", "--list", "LG HDR 4K"], "LG HDR 4K"),
            (["window", "displays", "extra"], "extra"),
        ):
            self.assert_rejected(args, f"unexpected argument {stray}")

    def test_window_option_requires_a_value(self) -> None:
        self.assert_rejected(["window", "display", "LG HDR 4K", "--window"], "--window requires a value")

    def test_missing_name_is_still_an_error(self) -> None:
        self.assert_rejected(["window", "display"], "window display requires a display name")

    def test_documented_forms_still_send_the_request(self) -> None:
        self.assert_sends(["window", "display", "LG HDR 4K"], "window.display", {"display": "LG HDR 4K"})
        self.assert_sends(["window", "display", "1"], "window.display", {"display": "1"})
        self.assert_sends(["window", "display", "--", "-odd name"], "window.display", {"display": "-odd name"})
        self.assert_sends(["window", "display", "--list"], "window.displays", {})
        self.assert_sends(["window", "display", "-l"], "window.displays", {})
        self.assert_sends(["window", "displays"], "window.displays", {})

    def test_window_option_targets_that_window(self) -> None:
        # Before or after the subcommand, --window must reach the request;
        # without it every main window moves.
        self.assert_sends(["--window", WIN, "window", "display", "LG HDR 4K"], "window.display",
                          {"display": "LG HDR 4K", "window_id": WIN})
        self.assert_sends(["window", "display", "LG HDR 4K", "--window", WIN], "window.display",
                          {"display": "LG HDR 4K", "window_id": WIN})
        self.assert_sends(["window", "display", "LG HDR 4K"], "window.display", {"window_id": None})


if __name__ == "__main__":
    unittest.main()
