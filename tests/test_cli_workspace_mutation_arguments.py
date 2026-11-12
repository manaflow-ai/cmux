#!/usr/bin/env python3
"""Workspace mutation commands reject arguments they don't accept.

`workspace close/select/rename/reconnect/disconnect/create`, their legacy
top-level spellings, and `reorder-workspace(s)` used to drop an unknown flag,
a missing option value, or a stray word and send the mutation anyway, so a
typo could still close, rename, disconnect or move a workspace. Each case runs
the real CLI against a fake socket that records requests: a rejected command
must exit non-zero and send no workspace mutation, and the documented forms
must still send the request they always did.
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
WS2 = "22222222-2222-4222-8222-222222222222"
WIN = "33333333-3333-4333-8333-333333333333"

MUTATIONS = {
    "workspace.close", "workspace.select", "workspace.rename",
    "workspace.remote.reconnect", "workspace.remote.disconnect",
    "workspace.create", "workspace.reorder", "workspace.reorder_many",
}


class Recorder(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            result = {"workspace_id": params.get("workspace_id", WS), "window_id": WIN, "index": 0}
            if method.startswith("workspace.reorder"):
                result["workspaces"] = []
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class WorkspaceMutationArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-ws-args-", dir="/tmp")
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

    def mutations(self) -> list[tuple[str, dict]]:
        return [call for call in self.server.calls if call[0] in MUTATIONS]  # type: ignore[attr-defined]

    def assert_rejected(self, args: list[str], message: str) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, f"{args} should fail:\n{output}")
            self.assertIn(message, output, f"{args}:\n{output}")
            self.assertEqual(self.mutations(), [], f"{args} sent a mutation:\n{output}")

    def assert_sends(self, args: list[str], method: str, expected: dict) -> None:
        with self.subTest(args=args):
            result = self.run_cli(*args)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, f"{args}:\n{output}")
            sent = self.mutations()
            self.assertEqual([m for m, _ in sent], [method], f"{args}:\n{output}")
            for key, value in expected.items():
                self.assertEqual(sent[0][1].get(key), value, f"{args} {key}:\n{sent}")

    def test_unknown_options_are_rejected(self) -> None:
        for args in (
            ["workspace", "close", "--workspace", WS, "--typo"],
            ["close-workspace", "--workspace", WS, "--typo"],
            ["workspace", "select", "--workspace", WS, "--typo"],
            ["select-workspace", "--workspace", WS, "--typo"],
            ["workspace", "rename", "--workspace", WS, "--title", "New", "--typo"],
            ["rename-workspace", "--workspace", WS, "--typo", "New"],
            ["workspace", "reconnect", "--workspace", WS, "--typo"],
            ["workspace", "disconnect", "--workspace", WS, "--typo"],
            ["reorder-workspace", "--workspace", WS, "--index", "0", "--typo"],
            ["reorder-workspaces", "--order", f"{WS},{WS2}", "--typo"],
        ):
            self.assert_rejected(args, "unknown option --typo")

    def test_missing_option_values_are_rejected(self) -> None:
        for args, option in (
            (["workspace", "close", "--workspace"], "--workspace"),
            (["workspace", "select", "--window"], "--window"),
            (["workspace", "rename", "--workspace", WS, "--title"], "--title"),
            (["workspace", "rename", "--title", "--workspace", WS], "--title"),
            (["workspace", "disconnect", "--workspace=", ], "--workspace"),
            (["reorder-workspace", "--workspace", WS, "--index"], "--index"),
            (["workspace", "create", "--name"], "--name"),
            (["workspace", "create", "--name", "--description", "x"], "--name"),
            (["new-workspace", "--cwd"], "--cwd"),
        ):
            self.assert_rejected(args, f"{option} requires a value")

    def test_stray_positionals_are_rejected(self) -> None:
        for args, stray in (
            (["workspace", "close", WS, "extra"], "extra"),
            (["close-workspace", "--workspace", WS, "extra"], "extra"),
            (["workspace", "select", WS, WS2], WS2),
            (["workspace", "reconnect", WS, "extra"], "extra"),
            (["reorder-workspaces", "--order", WS, "extra"], "extra"),
            (["workspace", "create", "extra"], "extra"),
            # With --workspace there is no room for a positional target too.
            (["workspace", "close", "--workspace", WS, "extra"], "extra"),
            (["workspace", "select", "--workspace", WS, "extra"], "extra"),
            (["workspace", "rename", "--workspace", WS, "--title", "New", "extra"], "extra"),
            (["workspace", "reconnect", "--workspace", WS, "extra"], "extra"),
            (["workspace", "disconnect", "--workspace=" + WS, "extra"], "extra"),
            (["reorder-workspace", "--workspace", WS, "--index", "0", "extra"], "extra"),
        ):
            self.assert_rejected(args, f"unexpected argument {stray}")

    def test_dash_leading_target_after_terminator_is_used_not_dropped(self) -> None:
        # After `--` the target is taken literally, so an invalid one fails
        # instead of falling back to the current or selected workspace.
        for args in (
            ["workspace", "close", "--", "--odd"],
            ["workspace", "select", "--", "--odd"],
            ["workspace", "rename", "--title", "New", "--", "--odd"],
            ["workspace", "reconnect", "--", "--odd"],
            ["workspace", "disconnect", "--", "--odd"],
        ):
            self.assert_rejected(args, "Invalid workspace handle: --odd")

    def test_documented_forms_still_send_the_mutation(self) -> None:
        self.assert_sends(["workspace", "close", WS, "--force"], "workspace.close",
                          {"workspace_id": WS, "force": True})
        self.assert_sends(["workspace", "close", "--workspace=" + WS], "workspace.close", {"workspace_id": WS})
        self.assert_sends(["workspace", "close", "--", WS], "workspace.close", {"workspace_id": WS})
        self.assert_sends(["close-workspace", "--workspace", WS], "workspace.close", {"workspace_id": WS})
        self.assert_sends(["workspace", "select", WS], "workspace.select", {"workspace_id": WS})
        self.assert_sends(["workspace", "rename", WS, "--title", "New name"], "workspace.rename",
                          {"workspace_id": WS, "title": "New name"})
        self.assert_sends(["rename-workspace", "--workspace", WS, "Two", "words"], "workspace.rename",
                          {"workspace_id": WS, "title": "Two words"})
        self.assert_sends(["rename-workspace", "--workspace", WS, "--", "--literal", "title"], "workspace.rename",
                          {"workspace_id": WS, "title": "--literal title"})
        self.assert_sends(["workspace", "disconnect", "--workspace", WS], "workspace.remote.disconnect",
                          {"workspace_id": WS})
        self.assert_sends(["workspace", "reconnect", WS], "workspace.remote.reconnect", {"workspace_id": WS})
        self.assert_sends(["reorder-workspace", WS, "--index", "0", "--dry-run"], "workspace.reorder",
                          {"workspace_id": WS, "index": 0, "dry_run": True})
        self.assert_sends(["workspace", "create", "--name", "Demo", "--focus", "false"], "workspace.create",
                          {"title": "Demo", "focus": False})
        self.assert_sends(["workspace", "create", "--name", "Demo", "--focus", "true"], "workspace.create",
                          {"title": "Demo", "focus": True})


if __name__ == "__main__":
    unittest.main()
