#!/usr/bin/env python3
"""`cmux canvas` subcommands reject arguments they don't accept.

The namespace skipped every `--word` together with the token after it
without checking the name, so a misspelled flag, a flag missing its value,
or an extra word still sent the canvas request (`canvas mode canvas --typo`,
`canvas new-pane --typo`). Each case runs the real CLI against a fake socket
that records requests: a rejected command must exit non-zero and send no
`canvas.*` request, and the documented forms must still send theirs.
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


WS = "11111111-1111-4111-8111-111111111111"
S1 = "22222222-2222-4222-8222-222222222222"
S2 = "33333333-3333-4333-8333-333333333333"
FRAME = ["--x", "0", "--y", "0", "--width", "800", "--height", "520"]


class Recorder(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            self.server.calls.append((request["method"], request.get("params", {})))  # type: ignore[attr-defined]
            response = {"ok": True, "result": {"workspace_id": WS, "surface_id": S1}, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class CanvasArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-canvas-args-", dir="/tmp")
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
            [self.cli, "--socket", self.socket_path, "canvas", *args],
            env=cli_environment(AppleLanguages="(en)"), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )

    def requests(self) -> list[tuple[str, dict]]:
        return [call for call in self.server.calls if call[0].startswith("canvas.")]  # type: ignore[attr-defined]

    def assert_rejected(self, args: list[str], message: str) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, f"{args} should fail:\n{output}")
            self.assertIn(message, output, f"{args}:\n{output}")
            self.assertEqual(self.requests(), [], f"{args} sent a canvas request:\n{output}")

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
            (["mode", "canvas", "--typo"], "--typo"),
            (["new-pane", "--typo"], "--typo"),
            (["set-frame", S1, "--x", "0", "--y", "0", "--width", "400", "--heigth", "300"], "--heigth"),
            (["info", "--typo"], "--typo"),
            (["align", "tidy", "--typo"], "--typo"),
            (["reveal", "--typo"], "--typo"),
            (["overview", "--typo"], "--typo"),
            (["zoom", "in", "--typo"], "--typo"),
            (["join", S1, S2, "--typo"], "--typo"),
            (["break", S1, "--typo"], "--typo"),
            (["select-tab", S1, "--typo"], "--typo"),
            (["set-viewport", "--x", "1", "--y", "2", "--typo"], "--typo"),
            (["new-pane", "--surface", S1], "--surface"),
        ):
            self.assert_rejected(args, f"unknown option {option}")

    def test_missing_option_values_are_rejected(self) -> None:
        for args, option in (
            (["mode", "canvas", "--workspace"], "--workspace"),
            (["set-frame", S1, "--x", "0", "--y", "0", "--width", "400", "--height"], "--height"),
            (["set-frame", S1, "--x", "--y", "0", "--width", "400", "--height", "300"], "--x"),
            (["set-viewport", "--x", "1", "--y"], "--y"),
            (["new-pane", "--type"], "--type"),
            (["reveal", "--surface"], "--surface"),
            (["join", S1, "--target"], "--target"),
        ):
            self.assert_rejected(args, f"{option} requires a value")

    def test_extra_arguments_are_rejected(self) -> None:
        for args, stray in (
            (["info", "extra"], "extra"),
            (["mode", "canvas", "extra"], "extra"),
            (["overview", "extra"], "extra"),
            (["zoom", "in", "out"], "out"),
            (["align", "tidy", "extra"], "extra"),
            (["reveal", S1, "extra"], "extra"),
            (["break", S1, "extra"], "extra"),
            (["break", "--surface", S1, "extra"], "extra"),
            (["select-tab", S1, S2], S2),
            (["join", S1, S2, "extra"], "extra"),
            (["set-frame", S1, S2, *FRAME], S2),
            (["set-viewport", "--x", "1", "--y", "2", "extra"], "extra"),
            (["new-pane", "extra"], "extra"),
        ):
            self.assert_rejected(args, f"unexpected argument {stray}")

    def test_documented_forms_still_send_the_request(self) -> None:
        self.assert_sends(["info"], "canvas.info", {})
        self.assert_sends(["info", "--workspace", WS], "canvas.info", {"workspace_id": WS})
        self.assert_sends(["mode", "canvas"], "canvas.set_mode", {"mode": "canvas"})
        self.assert_sends(["set-frame", S1, *FRAME], "canvas.set_frame",
                          {"surface_id": S1, "x": 0, "y": 0, "width": 800, "height": 520})
        self.assert_sends(["set-frame", "--surface", S1, "--x", "-100", "--y", "-40.5", "--width", "800", "--height", "520"],
                          "canvas.set_frame", {"surface_id": S1, "x": -100, "y": -40.5})
        self.assert_sends(["align", "tidy"], "canvas.align", {"command": "tidy"})
        self.assert_sends(["reveal"], "canvas.reveal", {"surface_id": None})
        self.assert_sends(["reveal", S1], "canvas.reveal", {"surface_id": S1})
        self.assert_sends(["overview"], "canvas.overview", {})
        self.assert_sends(["zoom", "in"], "canvas.zoom", {"direction": "in"})
        self.assert_sends(["join", S1, S2], "canvas.join", {"surface_id": S1, "target_surface_id": S2})
        self.assert_sends(["join", S1, "--target", S2], "canvas.join", {"surface_id": S1, "target_surface_id": S2})
        self.assert_sends(["break", S1], "canvas.break", {"surface_id": S1})
        self.assert_sends(["select-tab", "--surface", S1], "canvas.select_tab", {"surface_id": S1})
        self.assert_sends(["set-viewport", "--x", "400", "--y", "-260", "--zoom", "1.0"], "canvas.set_viewport",
                          {"x": 400, "y": -260, "zoom": 1.0})
        self.assert_sends(["new-pane", "--type", "terminal"], "canvas.new_pane", {"type": "terminal"})
        self.assert_sends(["new-pane"], "canvas.new_pane", {"type": None})


    def test_equals_and_terminator_forms(self) -> None:
        # `--name=value` is one token, and everything after `--` is positional;
        # the old scan skipped the token after either.
        self.assert_sends(["set-frame", "--x=0", "--y=-20", "--width=800", "--height=520", S1], "canvas.set_frame",
                          {"surface_id": S1, "x": 0, "y": -20, "width": 800})
        self.assert_sends(["info", "--workspace=" + WS], "canvas.info", {"workspace_id": WS})
        self.assert_sends(["mode", "--", "canvas"], "canvas.set_mode", {"mode": "canvas"})
        self.assert_sends(["reveal", "--", S1], "canvas.reveal", {"surface_id": S1})
        self.assert_rejected(["set-viewport", "--x=", "--y", "2"], "--x requires a value")


if __name__ == "__main__":
    unittest.main()
