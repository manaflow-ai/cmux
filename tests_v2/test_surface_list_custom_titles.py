#!/usr/bin/env python3
"""Regression: surface.list and list-panels should return custom tab titles."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli_json(cli: str, args: list[str]) -> dict:
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
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output: {proc.stdout!r} ({exc})")


def main() -> int:
    cli = _find_cli_binary()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.2)

            current_payload = client._call("surface.current", {"workspace_id": workspace_id}) or {}
            surface_id = str(current_payload.get("surface_id") or "")
            _must(bool(surface_id), f"surface.current returned no surface_id: {current_payload}")

            title = f"renamed-surface-{int(time.time() * 1000)}"
            renamed = client._call(
                "surface.action",
                {"surface_id": surface_id, "action": "rename", "title": title},
            ) or {}
            _must(str(renamed.get("title") or "") == title, f"surface.action rename failed: {renamed}")

            listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
            row = next((item for item in listed.get("surfaces") or [] if str(item.get("id") or "") == surface_id), None)
            _must(row is not None, f"surface.list missing renamed surface: {listed}")
            _must(str(row.get("title") or "") == title, f"surface.list should return custom title {title!r}: {row}")

            cli_listed = _run_cli_json(cli, ["list-panels", "--workspace", workspace_id])
            cli_row = next((item for item in cli_listed.get("surfaces") or [] if str(item.get("title") or "") == title), None)
            _must(cli_row is not None, f"list-panels missing renamed surface: {cli_listed}")
            _must(str(cli_row.get("title") or "") == title, f"list-panels should return custom title {title!r}: {cli_row}")
    finally:
        if workspace_id:
            with cmux(SOCKET_PATH) as cleanup_client:
                try:
                    cleanup_client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: surface.list and list-panels return custom surface titles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
