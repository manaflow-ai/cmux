#!/usr/bin/env python3
"""An explicit surface UUID or ref reaches its surface after the pane moved workspaces.

A pane keeps the CMUX_WORKSPACE_ID it started with when it moves to another
workspace. `close-surface --surface "$CMUX_SURFACE_ID"` and the other surface
commands paired that stale workspace with the surface and failed with
`Surface not found`, so a pane could not close itself. Each case runs the real
CLI against a fake socket that holds two workspaces in two windows and checks
which workspace the command addressed.
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


OLD_WINDOW_ID = "99999999-9999-4999-8999-999999999999"
NEW_WINDOW_ID = "77777777-7777-4777-8777-777777777777"
OLD_WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
NEW_WORKSPACE_ID = "22222222-2222-4222-8222-222222222222"
GONE_WORKSPACE_ID = "55555555-5555-4555-8555-555555555555"
STAYED_SURFACE_ID = "33333333-3333-4333-8333-333333333333"
MOVED_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
UNKNOWN_SURFACE_ID = "88888888-8888-4888-8888-888888888888"

SURFACES = {
    OLD_WORKSPACE_ID: [{"id": STAYED_SURFACE_ID, "ref": "surface:1", "index": 0, "focused": True,
                        "pane_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "pane_ref": "pane:1"}],
    NEW_WORKSPACE_ID: [{"id": MOVED_SURFACE_ID, "ref": "surface:2", "index": 0, "focused": True,
                        "pane_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "pane_ref": "pane:2"}],
}
WORKSPACES = {
    OLD_WINDOW_ID: [{"id": OLD_WORKSPACE_ID, "ref": "workspace:1", "index": 0, "title": "old"}],
    NEW_WINDOW_ID: [{"id": NEW_WORKSPACE_ID, "ref": "workspace:2", "index": 0, "title": "new"}],
}
# The commands that act on one surface, the option that names it, and the
# request each one ends with.
SURFACE_COMMANDS = [
    (["close-surface"], "--surface", "surface.close"),
    (["new-split", "right"], "--surface", "surface.split"),
    (["trigger-flash"], "--surface", "surface.trigger_flash"),
    (["tab-action", "--action", "pin"], "--surface", "tab.action"),
    (["focus-panel"], "--panel", "surface.focus"),
    (["clear-history"], "--surface", "surface.clear_history"),
    (["respawn-pane"], "--surface", "surface.respawn"),
]
# The ones that act on the caller's own pane when no surface is named.
OWN_PANE_COMMANDS = SURFACE_COMMANDS[:4]


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
                            "error": {"code": "not_found", "message": "Workspace not found"}}
            else:
                response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()

    def result(self, method: str, params: dict[str, object]) -> dict[str, object] | None:
        if method == "window.list":
            return {"windows": [{"id": OLD_WINDOW_ID, "ref": "window:1", "index": 0},
                                {"id": NEW_WINDOW_ID, "ref": "window:2", "index": 1}]}
        if method == "workspace.list":
            window_id = params.get("window_id", OLD_WINDOW_ID)
            return {"workspaces": WORKSPACES.get(str(window_id), [])}
        if method == "surface.list":
            surfaces = SURFACES.get(str(params.get("workspace_id")))
            return None if surfaces is None else {"surfaces": surfaces}
        return {"ok": True, "workspace_id": params.get("workspace_id"),
                "surface_id": params.get("surface_id")}


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class SurfaceHandleIgnoresStaleWorkspaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-stale-ws-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = resolve_cmux_cli()

    def run_cli(
        self, args: list[str], *, caller_workspace: str | None = OLD_WORKSPACE_ID
    ) -> tuple[subprocess.CompletedProcess[str], list[tuple[str, dict[str, object]]]]:
        """Run the CLI from a pane whose environment names `caller_workspace`."""
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
            if caller_workspace is not None:
                env["CMUX_WORKSPACE_ID"] = caller_workspace
            env["CMUX_SURFACE_ID"] = MOVED_SURFACE_ID
            proc = subprocess.run(
                [self.cli, "--socket", str(socket_path), *args],
                capture_output=True, text=True, check=False, env=env, timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        return proc, server.calls  # type: ignore[attr-defined]

    def assert_addressed(
        self, args: list[str], method: str, workspace_id: str, surface_ids: tuple[str, ...],
        **kwargs: str | None,
    ) -> list[tuple[str, dict[str, object]]]:
        proc, calls = self.run_cli(args, **kwargs)
        self.assertEqual(proc.returncode, 0, f"{args!r}: {proc.stdout} {proc.stderr}")
        sent = [params for name, params in calls if name == method]
        self.assertEqual(len(sent), 1, f"{args!r} should send {method} once: {calls!r}")
        self.assertEqual(sent[0].get("workspace_id"), workspace_id, f"{args!r}: {calls!r}")
        self.assertIn(sent[0].get("surface_id"), surface_ids, f"{args!r}: {calls!r}")
        return calls

    def test_surface_uuid_reaches_a_pane_that_moved(self) -> None:
        for command, option, method in SURFACE_COMMANDS:
            with self.subTest(command=command):
                self.assert_addressed(
                    [*command, option, MOVED_SURFACE_ID], method, NEW_WORKSPACE_ID, (MOVED_SURFACE_ID,))

    def test_surface_ref_reaches_a_pane_that_moved(self) -> None:
        # Some commands leave a ref for the app to resolve; the workspace is what was wrong.
        for command, option, method in SURFACE_COMMANDS:
            with self.subTest(command=command):
                self.assert_addressed(
                    [*command, option, "surface:2"], method, NEW_WORKSPACE_ID,
                    (MOVED_SURFACE_ID, "surface:2"))

    def test_surface_uuid_reaches_its_pane_after_the_old_workspace_closed(self) -> None:
        for command, option, method in SURFACE_COMMANDS:
            with self.subTest(command=command):
                self.assert_addressed(
                    [*command, option, MOVED_SURFACE_ID], method, NEW_WORKSPACE_ID, (MOVED_SURFACE_ID,),
                    caller_workspace=GONE_WORKSPACE_ID)

    def test_a_moved_pane_reaches_itself_without_naming_a_surface(self) -> None:
        # The CLI then takes the surface from CMUX_SURFACE_ID, which is still right.
        for command, _, method in OWN_PANE_COMMANDS:
            with self.subTest(command=command):
                self.assert_addressed(command, method, NEW_WORKSPACE_ID, (MOVED_SURFACE_ID,))

    def test_tab_ref_reaches_a_pane_that_moved(self) -> None:
        self.assert_addressed(
            ["tab-action", "--action", "pin", "--tab", "tab:2"], "tab.action",
            NEW_WORKSPACE_ID, (MOVED_SURFACE_ID, "surface:2"))

    def test_a_pane_that_did_not_move_keeps_its_workspace(self) -> None:
        for command, option, method in SURFACE_COMMANDS:
            with self.subTest(command=command):
                calls = self.assert_addressed(
                    [*command, option, STAYED_SURFACE_ID], method, OLD_WORKSPACE_ID, (STAYED_SURFACE_ID,))
                self.assertNotIn("window.list", [name for name, _ in calls], calls)

    def test_an_index_stays_in_the_callers_workspace(self) -> None:
        calls = self.assert_addressed(
            ["close-surface", "--surface", "0"], "surface.close", OLD_WORKSPACE_ID, (STAYED_SURFACE_ID,))
        self.assertNotIn("window.list", [name for name, _ in calls], calls)

    def test_explicit_workspace_is_not_second_guessed(self) -> None:
        proc, calls = self.run_cli(
            ["close-surface", "--workspace", OLD_WORKSPACE_ID, "--surface", MOVED_SURFACE_ID])
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("Surface not found", proc.stderr)
        self.assertNotIn("surface.close", [name for name, _ in calls], calls)

    def test_unknown_surface_closes_nothing(self) -> None:
        proc, calls = self.run_cli(["close-surface", "--surface", UNKNOWN_SURFACE_ID])
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("Surface not found", proc.stderr)
        self.assertNotIn("surface.close", [name for name, _ in calls], calls)

    def test_close_surface_outside_cmux_still_needs_a_workspace(self) -> None:
        proc, calls = self.run_cli(
            ["close-surface", "--surface", MOVED_SURFACE_ID], caller_workspace=None)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("requires --workspace or --window", proc.stderr)
        self.assertNotIn("surface.close", [name for name, _ in calls], calls)

        proc, calls = self.run_cli(
            ["close-surface", "--surface", MOVED_SURFACE_ID], caller_workspace="")
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertNotIn("surface.close", [name for name, _ in calls], calls)


if __name__ == "__main__":
    unittest.main()
