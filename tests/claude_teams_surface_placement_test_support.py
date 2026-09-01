#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PANE_ID = "33333333-3333-4333-8333-333333333333"
LEADER_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
TEAMMATE_SURFACE_ID = "77777777-7777-4777-8777-777777777777"
OTHER_WORKSPACE_ID = "22222222-2222-4222-8222-222222222222"
ALIAS_SURFACE_ID = "88888888-8888-4888-8888-888888888888"
CONCURRENT_SURFACE_IDS = (
    "99999999-9999-4999-8999-999999999999",
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
)


class FakeState:
    def __init__(self, workspaces: list[dict[str, object]] | None = None) -> None:
        self.requests: list[tuple[str, dict[str, object]]] = []
        self.workspaces = workspaces if workspaces is not None else [
            {"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1, "title": "team"}
        ]
        self.surface_create_lock = threading.Lock()
        self.surface_create_count = 0
        self.surfaces = [
            {
                "id": LEADER_SURFACE_ID,
                "ref": "surface:1",
                "pane_id": PANE_ID,
                "workspace_id": WORKSPACE_ID,
                "title": "leader",
            }
        ]

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.requests.append((method, dict(params)))
        if method == "system.identify":
            return {
                "focused": {
                    "workspace_id": WORKSPACE_ID,
                    "pane_id": PANE_ID,
                    "surface_id": LEADER_SURFACE_ID,
                }
            }
        if method == "workspace.list":
            return {"workspaces": [dict(workspace) for workspace in self.workspaces]}
        if method == "pane.list":
            return {"panes": [{"id": PANE_ID, "ref": "pane:1", "index": 0}]}
        if method == "surface.current":
            return {
                "workspace_id": WORKSPACE_ID,
                "pane_id": PANE_ID,
                "surface_id": LEADER_SURFACE_ID,
            }
        if method == "surface.list":
            workspace_id = params.get("workspace_id")
            surfaces = [
                surface for surface in self.surfaces
                if workspace_id is None or surface.get("workspace_id", WORKSPACE_ID) == workspace_id
            ]
            return {"surfaces": [dict(surface) for surface in surfaces]}
        if method == "surface.create":
            with self.surface_create_lock:
                created_surface_id = (
                    TEAMMATE_SURFACE_ID
                    if self.surface_create_count == 0
                    else CONCURRENT_SURFACE_IDS[
                        (self.surface_create_count - 1) % len(CONCURRENT_SURFACE_IDS)
                    ]
                )
                self.surface_create_count += 1
            self.surfaces.append(
                {
                    "id": created_surface_id,
                    "ref": "surface:2",
                    "pane_id": PANE_ID,
                    "workspace_id": WORKSPACE_ID,
                    "title": "teammate",
                }
            )
            return {
                "workspace_id": WORKSPACE_ID,
                "pane_id": PANE_ID,
                "surface_id": created_surface_id,
            }
        if method == "pane.surfaces":
            workspace_id = params.get("workspace_id")
            pane_id = params.get("pane_id")
            surfaces = [
                dict(surface) for surface in self.surfaces
                if surface.get("workspace_id", WORKSPACE_ID) == workspace_id
                and surface.get("pane_id") == pane_id
            ]
            if surfaces:
                surfaces[0]["selected"] = True
            return {"surfaces": surfaces}
        if method == "surface.close":
            surface_id = params.get("surface_id")
            self.surfaces = [
                surface for surface in self.surfaces
                if surface.get("id") != surface_id
            ]
            return {"ok": True}
        if method in {
            "surface.send_text",
            "surface.respawn",
            "surface.focus",
            "tab.action",
            "workspace.select",
            "workspace.close",
            "workspace.rename",
            "workspace.equalize_splits",
        }:
            return {"ok": True}
        raise RuntimeError(f"unsupported method: {method}")


class FakeServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, path: str, state: FakeState) -> None:
        self.state = state
        super().__init__(path, FakeHandler)


class FakeHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            decoded = line.decode("utf-8").rstrip("\r\n")
            capability_prefix = "_cmux_capability_v1 "
            if decoded.startswith(capability_prefix):
                envelope_parts = decoded.split(" ", 2)
                if len(envelope_parts) != 3 or not envelope_parts[1] or not envelope_parts[2]:
                    self.wfile.write(b"ERROR: malformed capability envelope\n")
                    self.wfile.flush()
                    continue
                decoded = envelope_parts[2]
            if decoded.startswith("auth "):
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue
            request = json.loads(decoded)
            try:
                result = self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"], request.get("params", {})
                )
                response = {"ok": True, "result": result, "id": request.get("id")}
            except Exception as exc:
                response = {
                    "ok": False,
                    "error": {"code": "not_found", "message": str(exc)},
                    "id": request.get("id"),
                }
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


def run_cli(
    cli_path: str,
    socket_path: Path,
    home: Path,
    args: list[str],
    placement: str | None = "surface",
    environment_overrides: dict[str, str | None] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": WORKSPACE_ID,
            "CMUX_SURFACE_ID": LEADER_SURFACE_ID,
            "TMUX_PANE": "%pane:1",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
        }
    )
    if placement is not None:
        env["CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"] = placement
    for key, value in (environment_overrides or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def run_targetless_window_action_regressions(cli_path: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-targetless-") as td:
        root = Path(td)
        socket_path = root / "cmux.sock"
        home = root / "home"
        home.mkdir()
        state = FakeState()
        server = FakeServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        mutations = {
            "surface.focus",
            "surface.close",
            "tab.action",
            "workspace.select",
            "workspace.close",
            "workspace.rename",
        }
        try:
            actions = [
                (
                    ["__tmux-compat", "select-window"],
                    "surface.focus",
                    {"workspace_id": WORKSPACE_ID, "surface_id": LEADER_SURFACE_ID},
                    "workspace.select",
                ),
                (
                    ["__tmux-compat", "rename-window", "renamed leader"],
                    "tab.action",
                    {
                        "workspace_id": WORKSPACE_ID,
                        "surface_id": LEADER_SURFACE_ID,
                        "action": "rename",
                        "title": "renamed leader",
                    },
                    "workspace.rename",
                ),
                (
                    ["__tmux-compat", "kill-window"],
                    "surface.close",
                    {"workspace_id": WORKSPACE_ID, "surface_id": LEADER_SURFACE_ID},
                    "workspace.close",
                ),
            ]
            for command, expected_method, expected_params, forbidden_method in actions:
                before = len(state.requests)
                result = run_cli(cli_path, socket_path, home, command)
                if result.returncode != 0:
                    raise AssertionError(f"target-less {command[1]} failed: {result.stderr.strip()}")
                observed = state.requests[before:]
                if (expected_method, expected_params) not in observed:
                    raise AssertionError(
                        f"target-less {command[1]} missed caller surface: {observed!r}"
                    )
                if any(method == forbidden_method for method, _ in observed):
                    raise AssertionError(
                        f"target-less {command[1]} mutated the workspace: {observed!r}"
                    )

            for ambient_surface in (LEADER_SURFACE_ID, None, "not-a-surface"):
                invalid_state = FakeState()
                if ambient_surface == LEADER_SURFACE_ID:
                    invalid_state.surfaces = []
                server.state = invalid_state
                result = run_cli(
                    cli_path,
                    socket_path,
                    home,
                    ["__tmux-compat", "select-window"],
                    environment_overrides={"CMUX_SURFACE_ID": ambient_surface},
                )
                if result.returncode == 0:
                    raise AssertionError(
                        f"target-less select-window accepted ambient surface {ambient_surface!r}"
                    )
                observed_mutations = [
                    method for method, _ in invalid_state.requests if method in mutations
                ]
                if observed_mutations:
                    raise AssertionError(
                        "invalid target-less window action mutated state via "
                        f"{observed_mutations!r}"
                    )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
