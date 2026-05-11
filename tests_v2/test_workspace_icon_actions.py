#!/usr/bin/env python3
"""Regression: workspace icons use the CmuxButtonIcon wire shape end-to-end."""

import glob
import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any

from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
logger = logging.getLogger(__name__)


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
    candidates.sort(key=os.path.getmtime, reverse=True)
    return candidates[0]


def _run_cli_json(cli: str, args: list[str]) -> dict[str, Any]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json", *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=5,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})") from exc


def _workspace_icon(c: cmux, workspace_id: str) -> dict[str, Any] | None:
    rows = (c._call("workspace.list", {}) or {}).get("workspaces") or []
    for row in rows:
        if str(row.get("id") or "") == workspace_id:
            icon = row.get("custom_icon")
            if icon is None or isinstance(icon, dict):
                return icon
            raise cmuxError(f"workspace.list returned invalid custom_icon payload for {workspace_id}: {icon!r}")
    raise cmuxError(f"workspace.list did not include workspace {workspace_id}")


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        created = c._call("workspace.create", {}) or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")

        try:
            emoji_payload = {"type": "emoji", "value": "🚀"}
            socket_set = c._call(
                "workspace.action",
                {"workspace_id": ws_id, "action": "set_icon", "icon": emoji_payload},
            ) or {}
            _must(socket_set.get("custom_icon") == emoji_payload, f"set_icon should echo CmuxButtonIcon payload: {socket_set}")
            _must(_workspace_icon(c, ws_id) == emoji_payload, "set_icon should update workspace.list custom_icon")

            cleared = c._call("workspace.action", {"workspace_id": ws_id, "action": "clear_icon"}) or {}
            _must(cleared.get("custom_icon") is None, f"clear_icon should report null custom_icon: {cleared}")
            _must(_workspace_icon(c, ws_id) is None, "clear_icon should reset workspace.list custom_icon")

            symbol_json = '{"type":"symbol","name":"folder.fill"}'
            cli_set = _run_cli_json(
                cli,
                ["workspace-action", "--workspace", ws_id, "--action", "set-icon", "--icon", symbol_json],
            )
            expected_symbol = {"type": "symbol", "name": "folder.fill"}
            _must(cli_set.get("custom_icon") == expected_symbol, f"CLI set-icon should return symbol payload: {cli_set}")
            _must(_workspace_icon(c, ws_id) == expected_symbol, "CLI set-icon should persist through socket state")
        finally:
            try:
                c.close_workspace(ws_id)
            except Exception:
                logger.exception("failed to close workspace %s during workspace icon cleanup", ws_id)

    print("PASS: workspace icon socket and CLI actions round-trip CmuxButtonIcon payloads")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
