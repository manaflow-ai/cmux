#!/usr/bin/env python3
"""Regression: legacy v1 panel-creation socket commands must not steal focus."""

from __future__ import annotations

import os
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _send_v1(command: str, *, expect_ok: bool = True) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect(SOCKET_PATH)
        sock.sendall((command + "\n").encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
            sock.settimeout(0.1)
    payload = b"".join(chunks).decode("utf-8", errors="replace").strip()
    if expect_ok and not payload.startswith("OK"):
        raise cmuxError(f"{command!r} failed: {payload!r}")
    return payload


def _focused_surface_id(client: cmux, workspace_id: str) -> str:
    surfaces = client.list_surfaces(workspace=workspace_id)
    for _, surface_id, focused in surfaces:
        if focused:
            return surface_id
    raise cmuxError(f"no focused surface in workspace {workspace_id}: {surfaces}")


def _surface_ids(client: cmux, workspace_id: str) -> set[str]:
    return {surface_id for _, surface_id, _ in client.list_surfaces(workspace=workspace_id)}


def _created_surface_id(response: str) -> str:
    parts = response.split(" ", 1)
    _must(len(parts) == 2 and parts[1], f"expected surface id in response: {response!r}")
    return parts[1]


def _sidebar_state(workspace_id: str) -> str:
    payload = _send_v1(f"sidebar_state --tab={workspace_id}", expect_ok=False)
    if payload.startswith("ERROR"):
        raise cmuxError(f"sidebar_state failed: {payload!r}")
    return payload


def main() -> int:
    created_workspaces: list[str] = []
    with cmux(SOCKET_PATH) as client:
        try:
            created_workspace = client.new_workspace()
            created_workspaces.append(created_workspace)
            client.select_workspace(created_workspace)
            time.sleep(0.2)

            baseline_workspace = client.current_workspace()
            baseline_focused_surface = _focused_surface_id(client, created_workspace)
            baseline_surfaces = _surface_ids(client, created_workspace)

            new_surface_response = _send_v1("new_surface")
            time.sleep(0.2)
            new_surface_id = _created_surface_id(new_surface_response)
            _must(new_surface_id in _surface_ids(client, created_workspace), "new_surface should create a surface")
            _must(client.current_workspace() == baseline_workspace, "new_surface should not retarget workspace selection")
            _must(
                _focused_surface_id(client, created_workspace) == baseline_focused_surface,
                "new_surface should preserve the focused surface for v1 callers",
            )

            open_browser_response = _send_v1("open_browser")
            time.sleep(0.2)
            browser_surface_id = _created_surface_id(open_browser_response)
            _must(browser_surface_id in _surface_ids(client, created_workspace), "open_browser should create a browser surface")
            _must(client.current_workspace() == baseline_workspace, "open_browser should not retarget workspace selection")
            _must(
                _focused_surface_id(client, created_workspace) == baseline_focused_surface,
                "open_browser should preserve the focused surface for v1 callers",
            )

            new_pane_response = _send_v1("new_pane --direction=right")
            time.sleep(0.2)
            split_surface_id = _created_surface_id(new_pane_response)
            current_surfaces = _surface_ids(client, created_workspace)
            _must(
                len(current_surfaces - baseline_surfaces) >= 3,
                f"expected all v1 panel creation commands to add surfaces: {current_surfaces}",
            )
            _must(split_surface_id in current_surfaces, "new_pane should create a split surface")
            _must(client.current_workspace() == baseline_workspace, "new_pane should not retarget workspace selection")
            _must(
                _focused_surface_id(client, created_workspace) == baseline_focused_surface,
                "new_pane should preserve the focused surface for v1 callers",
            )

            background_workspace = client.new_workspace()
            created_workspaces.append(background_workspace)
            client.select_workspace(background_workspace)
            time.sleep(0.2)

            target_directory = f"/tmp/cmux-v1-report-pwd-{int(time.time() * 1000)}"
            _send_v1(
                f"report_pwd {target_directory} --tab={created_workspace} --panel={baseline_focused_surface}"
            )
            deadline = time.time() + 5.0
            sidebar_state = ""
            while time.time() < deadline:
                sidebar_state = _sidebar_state(created_workspace)
                if f"focused_cwd={target_directory}" in sidebar_state:
                    break
                time.sleep(0.1)
            _must(
                f"focused_cwd={target_directory}" in sidebar_state,
                f"report_pwd should update the targeted background workspace: {sidebar_state!r}",
            )
            _must(
                client.current_workspace() == background_workspace,
                "report_pwd with explicit scope should not retarget workspace selection",
            )
        finally:
            for workspace_id in reversed(created_workspaces):
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: legacy v1 panel creation and prompt telemetry preserve focus and workspace selection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
