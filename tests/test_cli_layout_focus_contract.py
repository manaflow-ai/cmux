#!/usr/bin/env python3
"""CLI layout commands send focus-neutral v2 requests by default."""

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
PANE_ID = "22222222-2222-4222-8222-222222222222"
SURFACE_ID = "33333333-3333-4333-8333-333333333333"
NEW_PANE_ID = "44444444-4444-4444-8444-444444444444"
NEW_SURFACE_ID = "55555555-5555-4555-8555-555555555555"


class FakeCmuxState:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.calls.append((method, params))

        if method == "workspace.layout_export":
            return {
                "schema": "cmux.workspacePreset.v1",
                "name": params.get("name") or "Agent Workspace",
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "workspace": {
                    "name": "Agent Workspace",
                    "cwd": "/tmp/agent-workspace",
                    "layout": {
                        "pane": {
                            "surfaces": [
                                {
                                    "type": "terminal",
                                    "name": "shell",
                                    "selected": True,
                                    "focus": True,
                                }
                            ]
                        }
                    },
                },
            }
        if method == "workspace.create":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
            }
        if method in {"surface.split", "surface.split_off", "pane.create"}:
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": NEW_PANE_ID,
                "pane_ref": "pane:2",
                "surface_id": NEW_SURFACE_ID,
                "surface_ref": "surface:2",
            }
        if method == "surface.create":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": PANE_ID,
                "pane_ref": "pane:1",
                "surface_id": NEW_SURFACE_ID,
                "surface_ref": "surface:2",
            }
        if method == "surface.reorder":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": PANE_ID,
                "pane_ref": "pane:1",
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:1",
            }
        if method == "tab.action":
            return {
                "action": params.get("action", ""),
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:1",
            }
        raise RuntimeError(f"Unsupported fake cmux method: {method}")


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return
            request = json.loads(line.decode("utf-8"))
            try:
                result = self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"],
                    request.get("params", {}),
                )
                response = {"ok": True, "result": result, "id": request.get("id")}
            except Exception as exc:  # noqa: BLE001
                response = {
                    "ok": False,
                    "error": {"code": "fake_error", "message": str(exc)},
                    "id": request.get("id"),
                }
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    state: FakeCmuxState


def run_cli(
    cli: str,
    socket_path: str,
    args: list[str],
    env_overrides: dict[str, str] | None = None,
) -> str:
    env = dict(os.environ)
    for key in ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"]:
        env.pop(key, None)
    if env_overrides:
        env.update(env_overrides)
    proc = subprocess.run(
        [cli, "--socket", socket_path, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=5,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise AssertionError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def run_cli_without_socket(cli: str, args: list[str]) -> str:
    env = dict(os.environ)
    for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"]:
        env.pop(key, None)
    proc = subprocess.run(
        [cli, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=5,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise AssertionError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def assert_cli_fails(cli: str, socket_path: str, args: list[str], expected: str) -> None:
    env = dict(os.environ)
    for key in ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"]:
        env.pop(key, None)
    proc = subprocess.run(
        [cli, "--socket", socket_path, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=5,
    )
    if proc.returncode == 0:
        raise AssertionError(f"CLI unexpectedly succeeded ({' '.join(args)}): {proc.stdout}")
    merged = f"{proc.stdout}\n{proc.stderr}"
    if expected not in merged:
        raise AssertionError(f"expected failure containing {expected!r}, got {merged!r}")


def assert_last_call(
    state: FakeCmuxState,
    method: str,
    expected_params: dict[str, object],
) -> None:
    actual_method, actual_params = state.calls[-1]
    if actual_method != method:
        raise AssertionError(f"expected method {method}, got {actual_method}")
    for key, expected in expected_params.items():
        actual = actual_params.get(key)
        if actual != expected:
            raise AssertionError(
                f"{method} expected {key}={expected!r}, got {actual!r}; params={actual_params!r}"
            )


def main() -> int:
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-layout-focus-") as tmp:
        socket_path = str(Path(tmp) / "cmux.sock")
        layout_dir = str(Path(tmp) / "layouts")
        layout_env = {"CMUX_LAYOUT_PRESET_DIR": layout_dir}
        state = FakeCmuxState()
        server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            help_text = run_cli_without_socket(cli, ["layout", "--help"])
            if "Usage: cmux layout" not in help_text:
                raise AssertionError(f"layout help missing usage: {help_text!r}")

            run_cli(cli, socket_path, ["new-workspace", "--name", "agent"])
            assert_last_call(state, "workspace.create", {"title": "agent", "focus": False})

            exported = json.loads(run_cli(cli, socket_path, ["layout", "export"]))
            if exported.get("name") != "Agent-Workspace":
                raise AssertionError(f"layout export should sanitize workspace title names: {exported!r}")
            assert_last_call(state, "workspace.layout_export", {})

            run_cli(cli, socket_path, ["layout", "save", "dev"], layout_env)
            assert_last_call(state, "workspace.layout_export", {"name": "dev"})
            saved_path = Path(layout_dir) / "dev.json"
            saved = json.loads(saved_path.read_text())
            if saved.get("name") != "dev":
                raise AssertionError(f"layout save wrote wrong preset name: {saved!r}")

            run_cli(cli, socket_path, ["layout", "open", "dev"], layout_env)
            assert_last_call(state, "workspace.create", {"title": "Agent Workspace", "focus": False})
            if "layout" not in state.calls[-1][1]:
                raise AssertionError(f"layout open did not send layout params: {state.calls[-1]!r}")

            run_cli(
                cli,
                socket_path,
                ["new-split", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID, "right"],
            )
            assert_last_call(
                state,
                "surface.split",
                {"workspace_id": WORKSPACE_ID, "surface_id": SURFACE_ID, "direction": "right", "focus": False},
            )

            run_cli(cli, socket_path, ["new-pane", "--workspace", WORKSPACE_ID, "--direction", "down"])
            assert_last_call(
                state,
                "pane.create",
                {"workspace_id": WORKSPACE_ID, "direction": "down", "focus": False},
            )

            run_cli(cli, socket_path, ["new-surface", "--workspace", WORKSPACE_ID, "--pane", PANE_ID])
            assert_last_call(
                state,
                "surface.create",
                {"workspace_id": WORKSPACE_ID, "pane_id": PANE_ID, "focus": False},
            )

            run_cli(cli, socket_path, ["reorder-surface", "--surface", SURFACE_ID, "--index", "0"])
            assert_last_call(
                state,
                "surface.reorder",
                {"surface_id": SURFACE_ID, "index": 0, "focus": False},
            )

            run_cli(cli, socket_path, ["tab-action", "--action", "duplicate", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID])
            assert_last_call(
                state,
                "tab.action",
                {"action": "duplicate", "workspace_id": WORKSPACE_ID, "surface_id": SURFACE_ID, "focus": False},
            )

            run_cli(cli, socket_path, ["split-off", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID, "down"])
            assert_last_call(
                state,
                "surface.split_off",
                {"workspace_id": WORKSPACE_ID, "surface_id": SURFACE_ID, "direction": "down", "focus": False},
            )

            run_cli(
                cli,
                socket_path,
                ["drag-surface-to-split", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID, "--focus", "true", "right"],
            )
            assert_last_call(
                state,
                "surface.split_off",
                {"workspace_id": WORKSPACE_ID, "surface_id": SURFACE_ID, "direction": "right", "focus": True},
            )

            assert_cli_fails(cli, socket_path, ["new-split", "--bogus"], "new-split requires a direction")
            assert_cli_fails(cli, socket_path, ["split-off", "--surface", SURFACE_ID, "--bogus"], "split-off requires a direction")
            assert_cli_fails(cli, socket_path, ["break-pane", "--focus", "true", "--no-focus"], "--focus and --no-focus cannot be used together")
            assert_cli_fails(cli, socket_path, ["move-surface", "--workspace", WORKSPACE_ID], "move-surface requires --surface")
            assert_cli_fails(cli, socket_path, ["reorder-surface", "--workspace", WORKSPACE_ID], "reorder-surface requires --surface")
        finally:
            server.shutdown()
            server.server_close()

    print("PASS: CLI layout commands default to focus=false and split-off uses v2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
