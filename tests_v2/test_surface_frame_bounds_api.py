#!/usr/bin/env python3
"""Regression: surface.list and tree expose screen-space surface frames."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli_json(cli: str, args: list[str]) -> dict[str, Any]:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    try:
        return dict(json.loads(proc.stdout or "{}"))
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output: {proc.stdout!r} ({exc})")


def _is_frame(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    for key in ("x", "y", "width", "height"):
        raw = value.get(key)
        if not isinstance(raw, (int, float)):
            return False
    return value["width"] > 1 and value["height"] > 1


def _assert_surface_shape(surface: dict[str, Any], label: str) -> None:
    _must(_is_frame(surface.get("frame")), f"{label} missing valid frame: {surface}")
    _must(_is_frame(surface.get("bounds")), f"{label} missing valid bounds: {surface}")
    _must(surface["bounds"]["x"] == 0, f"{label} bounds x should be 0: {surface}")
    _must(surface["bounds"]["y"] == 0, f"{label} bounds y should be 0: {surface}")
    screen = surface.get("screen")
    _must(isinstance(screen, str) and screen.startswith("screen:"), f"{label} missing screen: {surface}")
    _must(surface.get("in_window") is True, f"{label} should be in-window: {surface}")


def _tree_surfaces(payload: dict[str, Any]) -> list[dict[str, Any]]:
    surfaces: list[dict[str, Any]] = []
    for window in payload.get("windows") or []:
        if not isinstance(window, dict):
            continue
        for workspace in window.get("workspaces") or []:
            if not isinstance(workspace, dict):
                continue
            for pane in workspace.get("panes") or []:
                if not isinstance(pane, dict):
                    continue
                surfaces.extend(s for s in pane.get("surfaces") or [] if isinstance(s, dict))
    return surfaces


def _wait_for_surface_frames(client: cmux, workspace_id: str, timeout_s: float = 8.0) -> dict[str, Any]:
    deadline = time.time() + timeout_s
    last_payload: dict[str, Any] = {}
    while time.time() < deadline:
        payload = client._call("surface.list", {"workspace_id": workspace_id}) or {}
        last_payload = dict(payload)
        surfaces = [s for s in payload.get("surfaces") or [] if isinstance(s, dict)]
        if surfaces and all(_is_frame(s.get("frame")) and _is_frame(s.get("bounds")) for s in surfaces):
            return last_payload
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for surface frames: {last_payload}")


def main() -> int:
    cli = _find_cli_binary()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)

            list_payload = _wait_for_surface_frames(client, workspace_id)
            list_surfaces = [s for s in list_payload.get("surfaces") or [] if isinstance(s, dict)]
            _must(bool(list_surfaces), f"surface.list returned no surfaces: {list_payload}")
            for surface in list_surfaces:
                _assert_surface_shape(surface, "surface.list")

            tree_payload = client._call("system.tree", {"workspace_id": workspace_id}) or {}
            tree_surfaces = _tree_surfaces(dict(tree_payload))
            _must(bool(tree_surfaces), f"system.tree returned no surfaces: {tree_payload}")
            for surface in tree_surfaces:
                _assert_surface_shape(surface, "system.tree")

            cli_list_payload = _run_cli_json(cli, ["list-surfaces", "--workspace", workspace_id])
            cli_surfaces = [s for s in cli_list_payload.get("surfaces") or [] if isinstance(s, dict)]
            _must(bool(cli_surfaces), f"cmux list-surfaces returned no surfaces: {cli_list_payload}")
            for surface in cli_surfaces:
                _assert_surface_shape(surface, "cmux list-surfaces")

            cli_tree_payload = _run_cli_json(cli, ["tree", "--workspace", workspace_id])
            cli_tree_surfaces = _tree_surfaces(cli_tree_payload)
            _must(bool(cli_tree_surfaces), f"cmux tree returned no surfaces: {cli_tree_payload}")
            for surface in cli_tree_surfaces:
                _assert_surface_shape(surface, "cmux tree")
    finally:
        if workspace_id:
            with cmux(SOCKET_PATH) as cleanup_client:
                try:
                    cleanup_client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: surface frames are exposed through surface.list and tree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
