#!/usr/bin/env python3
"""tmux split-window only takes the HUD path for the command OMX starts its HUD with.

A HUD split launches its command as the pane's initial command and skips the
teammate-column bookkeeping, so it is not equalized with the agent panes. The
classifier used to accept any command that mentioned `hud` once the split came
through the OMX shim, and any text containing `omx` and `hud` otherwise, so
`echo hud` or `echo 'notomx hud'` took that path too. Each case runs the real
CLI against a fake socket and checks which path the split took.
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
PANE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_ID = "44444444-4444-4444-8444-444444444444"
NEW_PANE_ID = "66666666-6666-4666-8666-666666666666"
NEW_SURFACE_ID = "77777777-7777-4777-8777-777777777777"

# What marks a split as launched through the OMX shim.
SHIM_KEYS = ("CMUX_OMX_CMUX_BIN", "CMUX_AGENT_LAUNCH_KIND")


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = request["method"]
            params = request.get("params", {})
            self.server.calls.append((method, params))  # type: ignore[attr-defined]
            response = {"ok": True, "result": self.result(method), "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()

    def result(self, method: str) -> dict[str, object]:
        created = any(name == "surface.split" for name, _ in self.server.calls)  # type: ignore[attr-defined]
        if method == "workspace.list":
            return {"workspaces": [{"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1, "title": "demo"}]}
        if method == "surface.list":
            surfaces = [{"id": SURFACE_ID, "ref": "surface:1", "focused": True,
                         "pane_id": PANE_ID, "pane_ref": "pane:1", "title": "leader"}]
            if created:
                surfaces.append({"id": NEW_SURFACE_ID, "ref": "surface:2", "focused": False,
                                 "pane_id": NEW_PANE_ID, "pane_ref": "pane:2", "title": "split"})
            return {"surfaces": surfaces}
        if method == "surface.current":
            return {"workspace_id": WORKSPACE_ID, "workspace_ref": "workspace:1",
                    "pane_id": PANE_ID, "pane_ref": "pane:1",
                    "surface_id": SURFACE_ID, "surface_ref": "surface:1"}
        if method == "pane.list":
            panes = [{"id": PANE_ID, "ref": "pane:1", "index": 1, "rows": 32, "columns": 120,
                      "cell_height_px": 18, "cell_width_px": 9}]
            if created:
                panes.append({"id": NEW_PANE_ID, "ref": "pane:2", "index": 2, "rows": 12,
                              "columns": 120, "cell_height_px": 18, "cell_width_px": 9})
            return {"panes": panes}
        if method == "pane.surfaces":
            return {"surfaces": [{"id": SURFACE_ID, "selected": True}]}
        if method == "surface.split":
            return {"surface_id": NEW_SURFACE_ID, "pane_id": NEW_PANE_ID}
        return {"ok": True}


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class OMXHudCommandMatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-omx-hud-match-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = resolve_cmux_cli()

    def split(self, command: list[str], *, through_shim: bool) -> list[tuple[str, dict[str, object]]]:
        """Run `tmux split-window <command>` and return the requests it sent."""
        case_dir = Path(tempfile.mkdtemp(dir=self.root))
        socket_path = case_dir / "cmux.sock"
        home = case_dir / "home"
        home.mkdir()
        cwd = case_dir / "project"
        cwd.mkdir()

        server = Server(str(socket_path), Handler)
        server.calls = []  # type: ignore[attr-defined]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = cli_environment(socket_path, home=home)
            for key in SHIM_KEYS:
                env.pop(key, None)
            env["CMUX_WORKSPACE_ID"] = "workspace:1"
            env["CMUX_SURFACE_ID"] = "surface:1"
            env["TMUX_PANE"] = f"%{PANE_ID}"
            if through_shim:
                env["CMUX_OMX_CMUX_BIN"] = self.cli
            proc = subprocess.run(
                [self.cli, "--socket", str(socket_path), "__tmux-compat", "split-window",
                 "-v", "-l", "4", "-d", "-c", str(cwd), *command],
                capture_output=True, text=True, check=False, env=env, timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertEqual(proc.returncode, 0, f"{command!r}: {proc.stdout} {proc.stderr}")
        return list(server.calls)  # type: ignore[attr-defined]

    def took_hud_path(self, calls: list[tuple[str, dict[str, object]]], command: list[str]) -> bool:
        splits = [params for method, params in calls if method == "surface.split"]
        self.assertEqual(len(splits), 1, f"{command!r} should split once: {calls!r}")
        launched_as_initial_command = "initial_command" in splits[0]
        equalized = any(method == "workspace.equalize_splits" for method, _ in calls)
        self.assertNotEqual(
            launched_as_initial_command, equalized,
            f"{command!r} took neither path cleanly: {calls!r}",
        )
        return launched_as_initial_command

    def test_omx_hud_invocations_take_the_hud_path(self) -> None:
        cases = [
            (["node '/opt/oh-my-codex/dist/omx.js' hud --watch"], False),
            (["omx", "hud", "--watch"], False),
            (["exec env OMX_SESSION_ID=s1 node '/opt/oh-my-codex/dist/cli/omx.js' hud --watch focused"], False),
            (["OMX_TMUX_SPLIT_OPERATION_MARKER='m1' exec env OMX_SESSION_ID=s1 "
              "'/usr/local/bin/node' '/opt/oh-my-codex/dist/cli/omx.js' hud --watch"], True),
            # OMX up to v0.20.4 sets and exports its split marker ahead of the HUD.
            (["OMX_TMUX_SPLIT_OPERATION_MARKER='m1'; export OMX_TMUX_SPLIT_OPERATION_MARKER; "
              "exec env OMX_TMUX_HUD_OWNER=1 OMX_TMUX_HUD_LEADER_PANE='%1' "
              "node /repo/dist/cli/omx.js hud --watch"], False),
            # A development checkout runs an entry script that is not named after OMX;
            # the shim is what says the split came from OMX.
            (["node /src/oh-my-dev/dist/cli/index.js hud --watch"], True),
        ]
        for command, through_shim in cases:
            with self.subTest(command=command, through_shim=through_shim):
                calls = self.split(command, through_shim=through_shim)
                self.assertTrue(self.took_hud_path(calls, command), calls)

    def test_other_commands_take_the_normal_split_path(self) -> None:
        cases = [
            (["echo hud"], True),
            (["echo", "hud"], True),
            (["echo hud --watch"], True),
            (["vim hud-notes.md"], True),
            (["echo 'notomx hud'"], False),
            (["echo omx hud --watch"], False),
            (["omx hud"], False),
            (["node /opt/tools/report.js hud --watch"], False),
            # The pane's shell would run the second command too.
            (["omx hud --watch && echo done"], False),
            (["X=\"$(echo marker)\" omx hud --watch"], False),
            (["OMX_TMUX_SPLIT_OPERATION_MARKER='m1'; export OMX_TMUX_SPLIT_OPERATION_MARKER; codex"], False),
            (["touch marker; export A; omx hud --watch"], False),
        ]
        for command, through_shim in cases:
            with self.subTest(command=command, through_shim=through_shim):
                calls = self.split(command, through_shim=through_shim)
                self.assertFalse(self.took_hud_path(calls, command), calls)


if __name__ == "__main__":
    unittest.main()
