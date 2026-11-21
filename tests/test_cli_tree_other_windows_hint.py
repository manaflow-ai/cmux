#!/usr/bin/env python3
"""`cmux tree` says when it left other windows out.

Without `--all`, `cmux tree` lists only the current window, and nothing in the
text said so: with several windows open it read as the whole app (#25248).
Each case runs the real CLI against a fake socket and checks the last line.
The hint is localized, so the checks look for the count and `--all`, not the
English wording.
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


WINDOW_IDS = [
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
    "33333333-3333-4333-8333-333333333333",
    "44444444-4444-4444-8444-444444444444",
]
WORKSPACE_ID = "55555555-5555-4555-8555-555555555555"


def tree_window(index: int) -> dict[str, object]:
    return {
        "id": WINDOW_IDS[index],
        "ref": f"window:{index + 1}",
        "index": index,
        "current": index == 0,
        "workspaces": [
            {"id": WORKSPACE_ID, "ref": "workspace:1", "index": 0, "title": "main", "panes": []}
        ] if index == 0 else [],
    }


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            result = self.result(method, params)
            if result is None:
                response = {"ok": False, "id": request.get("id"),
                            "error": {"code": "internal_error", "message": "unavailable"}}
            else:
                response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()

    def result(self, method: str, params: dict[str, object]) -> dict[str, object] | None:
        window_count = self.server.window_count  # type: ignore[attr-defined]
        if method == "system.tree":
            if params.get("all_windows") is True:
                windows = [tree_window(index) for index in range(window_count)]
            else:
                windows = [tree_window(0)]
            return {"active": None, "caller": None, "windows": windows}
        if method == "window.list":
            if self.server.window_list_fails:  # type: ignore[attr-defined]
                return None
            return {"windows": [
                {"id": WINDOW_IDS[index], "ref": f"window:{index + 1}", "index": index,
                 "workspace_count": 1 if index == 0 else 0}
                for index in range(window_count)
            ]}
        if method == "window.current":
            return {"window_id": WINDOW_IDS[0], "window_ref": "window:1"}
        return None


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class TreeOtherWindowsHintTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-tree-hint-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = resolve_cmux_cli()

    def run_cli(
        self, args: list[str], *, window_count: int, window_list_fails: bool = False
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        case_dir = Path(tempfile.mkdtemp(dir=self.root))
        socket_path = case_dir / "cmux.sock"
        home = case_dir / "home"
        home.mkdir()

        server = Server(str(socket_path), Handler)
        server.calls = []  # type: ignore[attr-defined]
        server.window_count = window_count  # type: ignore[attr-defined]
        server.window_list_fails = window_list_fails  # type: ignore[attr-defined]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = cli_environment(socket_path, home=home)
            env.pop("TMUX", None)
            env.pop("CMUX_WORKSPACE_ID", None)
            env.pop("CMUX_SURFACE_ID", None)
            proc = subprocess.run(
                [self.cli, "--socket", str(socket_path), *args],
                capture_output=True, text=True, check=False, env=env, timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        return proc, [name for name, _ in server.calls]  # type: ignore[attr-defined]

    def last_line(self, proc: subprocess.CompletedProcess[str]) -> str:
        self.assertEqual(proc.returncode, 0, f"{proc.stdout} {proc.stderr}")
        lines = proc.stdout.rstrip("\n").splitlines()
        self.assertTrue(lines, proc.stdout)
        return lines[-1]

    def test_names_the_other_windows(self) -> None:
        proc, _ = self.run_cli(["tree"], window_count=4)
        last = self.last_line(proc)
        self.assertIn("--all", last, proc.stdout)
        self.assertIn("3", last, proc.stdout)
        self.assertTrue(proc.stdout.startswith("window window:1"), proc.stdout)

    def test_names_one_other_window(self) -> None:
        proc, _ = self.run_cli(["tree"], window_count=2)
        last = self.last_line(proc)
        self.assertIn("--all", last, proc.stdout)
        self.assertIn("1", last, proc.stdout)

    def test_no_hint_with_one_window(self) -> None:
        proc, _ = self.run_cli(["tree"], window_count=1)
        self.assertNotIn("--all", proc.stdout)

    def test_no_hint_with_all(self) -> None:
        proc, calls = self.run_cli(["tree", "--all"], window_count=4)
        self.assertNotIn("--all", self.last_line(proc))
        self.assertEqual(proc.stdout.count("window window:"), 4, proc.stdout)
        self.assertNotIn("window.list", calls)

    def test_no_hint_for_a_named_window(self) -> None:
        proc, _ = self.run_cli(["tree", "--window", "window:1"], window_count=4)
        self.assertNotIn("--all", proc.stdout)

    def test_json_is_unchanged(self) -> None:
        proc, calls = self.run_cli(["tree", "--json"], window_count=4)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertEqual(len(payload["windows"]), 1, payload)
        self.assertNotIn("window.list", calls)

    def test_failed_window_list_still_prints_the_tree(self) -> None:
        proc, _ = self.run_cli(["tree"], window_count=4, window_list_fails=True)
        self.assertNotIn("--all", proc.stdout)
        self.assertTrue(proc.stdout.startswith("window window:1"), proc.stdout)
        self.assertEqual(proc.stderr, "")


if __name__ == "__main__":
    unittest.main()
