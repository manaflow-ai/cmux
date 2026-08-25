#!/usr/bin/env python3
"""Regression coverage for Claude Teams teammate tabs in the caller workspace."""

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PANE_ID = "33333333-3333-4333-8333-333333333333"
LEADER_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
TEAMMATE_SURFACE_ID = "77777777-7777-4777-8777-777777777777"


class FakeState:
    def __init__(self) -> None:
        self.requests: list[tuple[str, dict[str, object]]] = []
        self.surfaces = [
            {
                "id": LEADER_SURFACE_ID,
                "ref": "surface:1",
                "pane_id": PANE_ID,
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
            return {
                "workspaces": [
                    {"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1, "title": "team"}
                ]
            }
        if method == "pane.list":
            return {"panes": [{"id": PANE_ID, "ref": "pane:1", "index": 0}]}
        if method == "surface.current":
            return {
                "workspace_id": WORKSPACE_ID,
                "pane_id": PANE_ID,
                "surface_id": LEADER_SURFACE_ID,
            }
        if method == "surface.list":
            return {"surfaces": [dict(surface) for surface in self.surfaces]}
        if method == "surface.create":
            self.surfaces.append(
                {
                    "id": TEAMMATE_SURFACE_ID,
                    "ref": "surface:2",
                    "pane_id": PANE_ID,
                    "title": "teammate",
                }
            )
            return {
                "workspace_id": WORKSPACE_ID,
                "pane_id": PANE_ID,
                "surface_id": TEAMMATE_SURFACE_ID,
            }
        if method in {"surface.send_text", "surface.respawn"}:
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


def run_cli(cli_path: str, socket_path: Path, home: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": WORKSPACE_ID,
            "CMUX_SURFACE_ID": LEADER_SURFACE_ID,
            "TMUX_PANE": "%pane:1",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
            # This is the launch snapshot that the claude-teams wrapper passes
            # to its tmux compatibility child and restored teammate processes.
            "CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT": "surface",
        }
    )
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-surface-") as td:
        root = Path(td)
        socket_path = root / "cmux.sock"
        home = root / "home"
        home.mkdir()
        state = FakeState()
        server = FakeServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            created = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "new-window", "-d", "-P", "-F", "#{pane_id}", "--", "echo", "ready"],
            )
            if created.returncode != 0:
                print(f"FAIL: new-window failed: {created.stderr.strip()}")
                return 1

            alias = created.stdout.strip()
            if not alias.startswith("%cmux-surface-"):
                print(f"FAIL: expected a cmux surface pane alias, got {alias!r}")
                return 1

            create_requests = [params for method, params in state.requests if method == "surface.create"]
            if len(create_requests) != 1:
                print(f"FAIL: expected one surface.create, got {create_requests!r}")
                return 1
            create_params = create_requests[0]
            if create_params.get("workspace_id") != WORKSPACE_ID or create_params.get("pane_id") != PANE_ID:
                print(f"FAIL: surface.create targeted the wrong container: {create_params!r}")
                return 1
            startup_environment = create_params.get("startup_environment")
            if not isinstance(startup_environment, dict) or startup_environment.get("TMUX_PANE") != alias:
                print(f"FAIL: teammate surface did not receive TMUX_PANE={alias!r}: {create_params!r}")
                return 1
            if any(method == "workspace.create" for method, _ in state.requests):
                print("FAIL: surface placement unexpectedly created a sibling workspace")
                return 1

            respawned = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "respawn-pane", "-k", "-t", alias, "echo", "again"],
            )
            if respawned.returncode != 0:
                print(f"FAIL: alias respawn failed: {respawned.stderr.strip()}")
                return 1
            respawn_requests = [params for method, params in state.requests if method == "surface.respawn"]
            if not respawn_requests or respawn_requests[-1].get("surface_id") != TEAMMATE_SURFACE_ID:
                print(f"FAIL: alias respawn targeted the wrong surface: {respawn_requests!r}")
                return 1
            if "CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT='surface'" not in str(respawn_requests[-1].get("command", "")):
                print(f"FAIL: alias respawn did not preserve surface placement: {respawn_requests!r}")
                return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    print("PASS: Claude Teams can spawn teammate surfaces in the caller workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
