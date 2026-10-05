#!/usr/bin/env python3
"""`cmux workspace status` and `cmux todo` reject arguments they don't accept.

Both used to drop an unknown option, an option without its value, or an
extra word and send the request anyway, so `todo check 1 --typo` still
changed the item and `todo add "x" --state` created it with the default
state. Each case runs the real CLI against a fake socket that records
requests: a rejected command must exit non-zero and send no status or todo
request, and the documented forms must still send the request they always
did, including literal text after `--`.
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
WIN = "22222222-2222-4222-8222-222222222222"
ITEM = "33333333-3333-4333-8333-333333333333"


class Recorder(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            result = {"workspace_id": WS, "window_id": WIN, "items": [],
                      "effective": "todo", "inferred": "todo"}
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class TodoStatusArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-todo-args-", dir="/tmp")
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
                if call[0].startswith(("workspace.todo.", "workspace.status."))]

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
        for args in (
            ["workspace", "status", "cycle", "--typo"],
            ["workspace", "status", "set", "done", "--typo"],
            ["todo", "list", "--typo"],
            ["todo", "add", "x", "--typo"],
            ["todo", "check", "1", "--typo"],
            ["todo", "uncheck", "1", "--typo"],
            ["todo", "start", "1", "--typo"],
            ["todo", "edit", "1", "new", "--typo"],
            ["todo", "rm", "1", "--typo"],
            ["todo", "move", "1", "2", "--typo"],
            ["todo", "clear", "--typo"],
            ["todo", "set", "[]", "--typo"],
            ["todo", "open", "--typo"],
        ):
            self.assert_rejected(args, "unknown option --typo")

    def test_missing_option_values_are_rejected(self) -> None:
        for args, option in (
            (["todo", "add", "x", "--state"], "--state"),
            (["todo", "add", "x", "--origin"], "--origin"),
            (["todo", "add", "x", "--state", "--origin", "user"], "--state"),
            (["todo", "list", "--workspace"], "--workspace"),
            (["todo", "check", "1", "--window"], "--window"),
            (["workspace", "status", "cycle", "--workspace"], "--workspace"),
        ):
            self.assert_rejected(args, f"{option} requires a value")

    def test_stray_arguments_are_rejected(self) -> None:
        for args, stray in (
            (["workspace", "status", "cycle", "extra"], "extra"),
            (["workspace", "status", "set", "done", "extra"], "extra"),
            (["todo", "list", "extra"], "extra"),
            (["todo", "check", "1", "2"], "2"),
            (["todo", "rm", "1", "2"], "2"),
            (["todo", "move", "1", "2", "3"], "3"),
            (["todo", "clear", "extra"], "extra"),
            (["todo", "open", "extra"], "extra"),
            (["todo", "set", "[]", "extra"], "extra"),
        ):
            self.assert_rejected(args, f"unexpected argument {stray}")

    def test_documented_forms_still_send_the_request(self) -> None:
        self.assert_sends(["workspace", "status"], "workspace.status.get", {"workspace_id": WS})
        self.assert_sends(["workspace", "status", "set", "done"], "workspace.status.set", {"status": "done"})
        self.assert_sends(["workspace", "status", "--workspace", WS, "cycle"], "workspace.status.cycle",
                          {"workspace_id": WS})
        self.assert_sends(["todo", "list", "--workspace", WS], "workspace.todo.list", {"workspace_id": WS})
        self.assert_sends(["todo", "add", "Buy", "milk", "--state", "pending", "--origin", "user"],
                          "workspace.todo.add", {"text": "Buy milk", "state": "pending", "origin": "user"})
        self.assert_sends(["todo", "check", "2"], "workspace.todo.set_state", {"index": 1, "state": "completed"})
        self.assert_sends(["todo", "start", ITEM], "workspace.todo.set_state", {"id": ITEM, "state": "in-progress"})
        self.assert_sends(["todo", "edit", "1", "new", "text"], "workspace.todo.edit",
                          {"index": 0, "text": "new text"})
        self.assert_sends(["todo", "rm", "1"], "workspace.todo.remove", {"index": 0})
        self.assert_sends(["todo", "move", "1", "3"], "workspace.todo.move", {"index": 0, "to_index": 2})
        self.assert_sends(["todo", "clear"], "workspace.todo.clear", {"workspace_id": WS})
        self.assert_sends(["todo", "set", '[{"text":"a"}]'], "workspace.todo.set", {"items": [{"text": "a"}]})
        self.assert_sends(["todo", "open"], "workspace.todo.open", {"workspace_id": WS})

    def test_text_after_terminator_is_literal(self) -> None:
        self.assert_sends(["todo", "add", "--", "--json"], "workspace.todo.add", {"text": "--json"})
        self.assert_sends(["todo", "add", "--", "fix", "-v", "flag"], "workspace.todo.add", {"text": "fix -v flag"})
        self.assert_sends(["todo", "edit", "1", "--", "--draft"], "workspace.todo.edit",
                          {"index": 0, "text": "--draft"})


if __name__ == "__main__":
    unittest.main()
