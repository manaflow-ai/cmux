#!/usr/bin/env python3
"""`workspace group` subcommands reject arguments they don't accept.

Each mutating subcommand used to drop an unknown flag, a flag without its
value, or an extra word and send the group request anyway, so a typo could
still delete a group (and close its workspaces), move, add, recolor or
rename it. Each case runs the real CLI against a fake socket that records
requests: a rejected command must exit non-zero and send no group request,
and the documented forms must still send the request they always did.
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


G1 = "11111111-1111-4111-8111-111111111111"
G2 = "22222222-2222-4222-8222-222222222222"
WS = "33333333-3333-4333-8333-333333333333"
WIN = "44444444-4444-4444-8444-444444444444"


class Recorder(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            if method == "window.current":
                result = {"window_id": WIN, "window_ref": "window:1"}
            else:
                result = {"group": {"id": params.get("group_id", G1), "ref": "workspace_group:1"},
                          "workspace_id": WS, "window_id": WIN}
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class WorkspaceGroupArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-group-args-", dir="/tmp")
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
            [self.cli, "--socket", self.socket_path, "workspace", "group", *args],
            env=cli_environment(AppleLanguages="(en)"), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )

    def group_requests(self) -> list[tuple[str, dict]]:
        return [call for call in self.server.calls if call[0].startswith("workspace.group.")]  # type: ignore[attr-defined]

    def assert_rejected(self, args: list[str], message: str) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, f"{args} should fail:\n{output}")
            self.assertIn(message, output, f"{args}:\n{output}")
            self.assertEqual(self.group_requests(), [], f"{args} sent a group request:\n{output}")

    def assert_sends(self, args: list[str], method: str, expected: dict) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, f"{args}:\n{output}")
            sent = self.group_requests()
            self.assertEqual([m for m, _ in sent], [method], f"{args}:\n{output}")
            for key, value in expected.items():
                self.assertEqual(sent[0][1].get(key), value, f"{args} {key}:\n{sent}")

    def test_unknown_options_are_rejected(self) -> None:
        for args in (
            ["delete", G1, "--close-workspaces", "--typo"],
            ["ungroup", G1, "--typo"],
            ["move", G1, "--before", G2, "--typo"],
            ["add", "--group", G1, "--workspace", WS, "--typo"],
            ["remove", "--workspace", WS, "--typo"],
            ["set-anchor", "--group", G1, "--workspace", WS, "--typo"],
            ["set-color", G1, "--hex", "#C0392B", "--typo"],
            ["set-icon", G1, "--symbol", "star", "--typo"],
            ["new-workspace", G1, "--typo"],
            ["rename", G1, "--name", "New", "--typo"],
            ["create", "--name", "G", "--typo"],
            ["collapse", G1, "--typo"],
            ["pin", G1, "--typo"],
            ["focus", G1, "--typo"],
        ):
            self.assert_rejected(args, "unknown option --typo")

    def test_missing_option_values_are_rejected(self) -> None:
        for args, option in (
            (["set-color", G1, "--hex"], "--hex"),
            (["set-color", G1, "--color"], "--color"),
            (["set-icon", G1, "--symbol"], "--symbol"),
            (["move", G1, "--to-index"], "--to-index"),
            (["move", G1, "--before", "--after", G2], "--before"),
            (["add", "--group", "--workspace", WS], "--group"),
            (["remove", "--workspace"], "--workspace"),
            (["new-workspace", G1, "--placement"], "--placement"),
            (["rename", G1, "--name"], "--name"),
            (["create", "--from"], "--from"),
            (["delete", "--group"], "--group"),
        ):
            self.assert_rejected(args, f"{option} requires a value")

    def test_stray_positionals_are_rejected(self) -> None:
        for args, stray in (
            (["delete", G1, G2, "--close-workspaces"], G2),
            (["delete", "--group", G1, "extra"], "extra"),
            (["add", "--group", G1, "--workspace", WS, "extra"], "extra"),
            (["remove", WS, "extra"], "extra"),
            (["collapse", G1, "extra"], "extra"),
            (["rename", G1, "New", "extra"], "extra"),
            (["rename", G1, "--name", "New", "extra"], "extra"),
            (["create", "Name", "extra"], "extra"),
        ):
            self.assert_rejected(args, f"unexpected argument {stray}")

    def test_documented_forms_still_send_the_request(self) -> None:
        self.assert_sends(["delete", G1, "--close-workspaces"], "workspace.group.delete",
                          {"group_id": G1, "close_workspaces": True})
        self.assert_sends(["delete", G1], "workspace.group.ungroup", {"group_id": G1})
        self.assert_sends(["ungroup", "--group", G1, "--remove-generated-anchor"], "workspace.group.ungroup",
                          {"group_id": G1, "remove_generated_anchor": True})
        self.assert_sends(["rename", G1, "--name", "New"], "workspace.group.rename", {"group_id": G1, "name": "New"})
        self.assert_sends(["rename", G1, "New"], "workspace.group.rename", {"group_id": G1, "name": "New"})
        # The --window value is not the new name, and after -- the name is literal.
        self.assert_sends(["rename", G1, "--window", WIN, "New"], "workspace.group.rename",
                          {"group_id": G1, "name": "New"})
        self.assert_sends(["rename", G1, "--", "--draft"], "workspace.group.rename",
                          {"group_id": G1, "name": "--draft"})
        self.assert_sends(["collapse", G1], "workspace.group.collapse", {"group_id": G1})
        self.assert_sends(["add", "--group", G1, "--workspace", WS], "workspace.group.add",
                          {"group_id": G1, "workspace_id": WS})
        self.assert_sends(["remove", WS], "workspace.group.remove", {"workspace_id": WS})
        self.assert_sends(["set-anchor", "--group", G1, "--workspace", WS], "workspace.group.set_anchor",
                          {"group_id": G1, "workspace_id": WS})
        self.assert_sends(["new-workspace", G1, "--placement", "top"], "workspace.group.new_workspace",
                          {"group_id": G1, "placement": "top"})
        self.assert_sends(["set-color", G1, "--hex", "#C0392B"], "workspace.group.set_color",
                          {"group_id": G1, "hex": "#C0392B"})
        self.assert_sends(["set-color", G1, "--color", "#C0392B"], "workspace.group.set_color", {"hex": "#C0392B"})
        self.assert_sends(["set-color", G1], "workspace.group.set_color", {"hex": ""})
        self.assert_sends(["set-color", G1, "--hex", ""], "workspace.group.set_color", {"hex": ""})
        self.assert_sends(["set-icon", G1, "--icon", "star"], "workspace.group.set_icon", {"symbol": "star"})
        self.assert_sends(["move", G1, "--to-index", "0"], "workspace.group.move", {"group_id": G1, "to_index": 0})
        self.assert_sends(["move", G1, "--after", G2], "workspace.group.move",
                          {"group_id": G1, "after_group_id": G2})
        self.assert_sends(["create", "--name", "G", "--from", WS], "workspace.group.create",
                          {"name": "G", "child_workspace_ids": [WS]})
        self.assert_sends(["focus", G1], "workspace.group.focus", {"group_id": G1})


if __name__ == "__main__":
    unittest.main()
