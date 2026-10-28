#!/usr/bin/env python3
"""`cmux textbox <toggle|show|hide|state>` drives a terminal's TextBox Input.

Issue https://github.com/manaflow-ai/cmux/issues/26541: Toggle TextBox Input
was reachable only from the command palette and a shortcut, so scripts and
agents had no way to open or close it. Each case runs the real CLI against a
fake socket and checks the request it sends and what it prints.
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


WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
CALLER_SURFACE_ID = "33333333-3333-4333-8333-333333333333"
OTHER_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
SURFACES = [
    {"id": CALLER_SURFACE_ID, "ref": "surface:1", "index": 0, "focused": False},
    {"id": OTHER_SURFACE_ID, "ref": "surface:2", "index": 1, "focused": True},
]


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            response = {"ok": True, "id": request.get("id"), "result": self.result(method, params)}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()

    def result(self, method: str, params: dict[str, object]) -> dict[str, object]:
        if method == "workspace.list":
            return {"workspaces": [{"id": WORKSPACE_ID, "ref": "workspace:1", "index": 0}]}
        if method == "surface.list":
            return {"surfaces": SURFACES}
        if method.startswith("surface.textbox."):
            surface_id = params.get("surface_id")
            ref = next((s["ref"] for s in SURFACES if s["id"] == surface_id), "surface:9")
            return {
                "workspace_id": WORKSPACE_ID, "workspace_ref": "workspace:1",
                "surface_id": surface_id, "surface_ref": ref,
                "window_id": None, "window_ref": None,
                "visible": method != "surface.textbox.hide", "changed": method != "surface.textbox.state",
            }
        return {}


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class TextBoxCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-textbox-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = resolve_cmux_cli()

    def run_cli(self, args: list[str]) -> tuple[subprocess.CompletedProcess[str], list[tuple[str, dict]]]:
        case_dir = Path(tempfile.mkdtemp(dir=self.root))
        socket_path = case_dir / "cmux.sock"
        home = case_dir / "home"
        home.mkdir()
        server = Server(str(socket_path), Handler)
        server.calls = []  # type: ignore[attr-defined]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = cli_environment(socket_path, home=home)
            env.pop("TMUX", None)
            env["CMUX_WORKSPACE_ID"] = WORKSPACE_ID
            env["CMUX_SURFACE_ID"] = CALLER_SURFACE_ID
            proc = subprocess.run(
                [self.cli, "--socket", str(socket_path), *args],
                capture_output=True, text=True, check=False, env=env, timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        return proc, server.calls  # type: ignore[attr-defined]

    def textbox_calls(self, calls: list[tuple[str, dict]]) -> list[tuple[str, dict]]:
        return [(name, params) for name, params in calls if name.startswith("surface.textbox.")]

    def test_each_verb_sends_its_method_for_the_calling_terminal(self) -> None:
        for verb in ("toggle", "show", "hide", "state"):
            with self.subTest(verb=verb):
                proc, calls = self.run_cli(["textbox", verb])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                sent = self.textbox_calls(calls)
                self.assertEqual([name for name, _ in sent], [f"surface.textbox.{verb}"], calls)
                self.assertEqual(sent[0][1].get("surface_id"), CALLER_SURFACE_ID, calls)
                self.assertEqual(sent[0][1].get("workspace_id"), WORKSPACE_ID, calls)
                self.assertNotIn("focus", sent[0][1], calls)
                visible = "false" if verb == "hide" else "true"
                self.assertEqual(proc.stdout, f"OK surface:1 workspace:1 visible={visible}\n")

    def test_an_explicit_surface_overrides_the_caller(self) -> None:
        for option in ("--surface", "--panel"):
            with self.subTest(option=option):
                proc, calls = self.run_cli(["textbox", "show", option, OTHER_SURFACE_ID])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                sent = self.textbox_calls(calls)
                self.assertEqual(sent[0][1].get("surface_id"), OTHER_SURFACE_ID, calls)

    def test_an_index_names_a_surface_in_the_workspace(self) -> None:
        proc, calls = self.run_cli(["textbox", "toggle", "--surface", "1"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.textbox_calls(calls)[0][1].get("surface_id"), OTHER_SURFACE_ID, calls)

    def test_focus_is_sent_only_when_asked(self) -> None:
        for verb in ("toggle", "show"):
            with self.subTest(verb=verb):
                proc, calls = self.run_cli(["textbox", verb, "--focus"])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIs(self.textbox_calls(calls)[0][1].get("focus"), True, calls)

    def test_json_output_carries_visible_and_changed(self) -> None:
        proc, _ = self.run_cli(["--json", "textbox", "state"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertIs(payload["visible"], True)
        self.assertIs(payload["changed"], False)
        # Refs by default, like the other surface commands; --id-format both adds UUIDs.
        self.assertEqual(payload["surface_ref"], "surface:1")
        proc, _ = self.run_cli(["--json", "--id-format", "both", "textbox", "state"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["surface_id"], CALLER_SURFACE_ID)

    def test_bad_usage_sends_nothing(self) -> None:
        for args in (
            ["textbox"],
            ["textbox", "open"],
            ["textbox", "toggle", "show"],
            ["textbox", "hide", "--focus"],
            ["textbox", "state", "--focus"],
        ):
            with self.subTest(args=args):
                proc, calls = self.run_cli(args)
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertIn("Usage: cmux textbox", proc.stderr)
                self.assertEqual(self.textbox_calls(calls), [], calls)

    def test_help_needs_no_socket(self) -> None:
        proc = subprocess.run(
            [self.cli, "textbox", "--help"],
            capture_output=True, text=True, check=False, env=cli_environment(), timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Usage: cmux textbox <toggle|show|hide|state>", proc.stdout)
        self.assertIn("--focus", proc.stdout)


if __name__ == "__main__":
    unittest.main()
