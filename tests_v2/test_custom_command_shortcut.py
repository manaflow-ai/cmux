#!/usr/bin/env python3
"""Regression: custom command shortcuts spawn a new surface and run in it."""

from __future__ import annotations

import base64
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
KEYBINDINGS_PATH = Path.home() / ".config" / "cmux" / "keybindings.json"
SHORTCUT = "cmd+ctrl+shift+k"


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _surface_rows(client: cmux, workspace_id: str) -> list[dict]:
    payload = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    return list(payload.get("surfaces") or [])


def _pane_count(client: cmux, workspace_id: str) -> int:
    payload = client._call("pane.list", {"workspace_id": workspace_id}) or {}
    return len(payload.get("panes") or [])


def _read_surface_text(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "scrollback": True,
        },
    ) or {}
    if "text" in payload:
        return str(payload.get("text") or "")
    encoded = str(payload.get("base64") or "")
    raw = base64.b64decode(encoded) if encoded else b""
    return raw.decode("utf-8", errors="replace")


def _wait_for_new_surface(
    client: cmux,
    workspace_id: str,
    before_ids: set[str],
    timeout_s: float = 10.0,
) -> dict:
    deadline = time.time() + timeout_s
    last_rows: list[dict] = []
    while time.time() < deadline:
        rows = _surface_rows(client, workspace_id)
        new_rows = [row for row in rows if str(row.get("id") or "") not in before_ids]
        if len(new_rows) == 1:
            return new_rows[0]
        last_rows = rows
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for a new surface in {workspace_id}: {last_rows}")


def _wait_for_text(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    needle: str,
    timeout_s: float = 10.0,
) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        last_text = _read_surface_text(client, workspace_id, surface_id)
        if needle in last_text:
            return last_text
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r} in surface {surface_id}: {last_text!r}")


def _write_keybindings_config(payload: dict) -> bytes | None:
    KEYBINDINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    previous = KEYBINDINGS_PATH.read_bytes() if KEYBINDINGS_PATH.exists() else None
    KEYBINDINGS_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return previous


def _restore_keybindings_config(previous: bytes | None) -> None:
    if previous is None:
        try:
            KEYBINDINGS_PATH.unlink()
        except FileNotFoundError:
            pass
        return
    KEYBINDINGS_PATH.write_bytes(previous)


def main() -> int:
    previous_keybindings = None
    workspace_dir = Path(tempfile.mkdtemp(prefix="cmux-custom-command-"))

    token = f"custom-command-{int(time.time() * 1000)}"
    command = (
        "printf 'CMUX_CUSTOM_COMMAND_OK=%s id=%s workspace=%s pane=%s pwd=%s\\n' "
        f"'{token}' "
        "\"$CMUX_CUSTOM_COMMAND_ID\" "
        "\"$CMUX_WORKSPACE_CWD\" "
        "\"$CMUX_PANE_CWD\" "
        "\"$PWD\""
    )

    config = {
        "version": 1,
        "custom_commands": [
            {
                "id": "launch-custom-command-right",
                "shortcut": SHORTCUT,
                "command": command,
                "label": "Launch custom command",
                "target": "split_right",
                "cwd": "workspace",
            }
        ],
    }

    with cmux(SOCKET_PATH) as client:
        baseline_workspace = client.current_workspace()
        created_workspace = ""
        try:
            previous_keybindings = _write_keybindings_config(config)
            time.sleep(0.5)

            created = client._call(
                "workspace.create",
                {
                    "title": "custom_command_shortcut_test",
                    "cwd": str(workspace_dir),
                },
            ) or {}
            created_workspace = str(created.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {created}")

            client.select_workspace(created_workspace)
            client.activate_app()
            time.sleep(0.5)

            before_rows = _surface_rows(client, created_workspace)
            before_ids = {str(row.get("id") or "") for row in before_rows if row.get("id")}
            before_panes = _pane_count(client, created_workspace)

            client.simulate_shortcut(SHORTCUT)

            new_surface = _wait_for_new_surface(client, created_workspace, before_ids)
            new_surface_id = str(new_surface.get("id") or "")
            _must(bool(new_surface_id), f"New surface row missing id: {new_surface}")

            after_panes = _pane_count(client, created_workspace)
            _must(
                after_panes == before_panes + 1,
                f"Expected pane count to increase by 1, got before={before_panes} after={after_panes}",
            )

            requested_cwd = str(new_surface.get("requested_working_directory") or "")
            _must(
                requested_cwd == str(workspace_dir),
                f"Expected new surface requested_working_directory={workspace_dir}, got {requested_cwd!r}: {new_surface}",
            )

            text = _wait_for_text(client, created_workspace, new_surface_id, f"CMUX_CUSTOM_COMMAND_OK={token}")
            _must(
                "id=launch-custom-command-right" in text,
                f"Expected CMUX_CUSTOM_COMMAND_ID in terminal output: {text!r}",
            )
            _must(
                f"workspace={workspace_dir}" in text,
                f"Expected CMUX_WORKSPACE_CWD in terminal output: {text!r}",
            )
            _must(
                f"pane={workspace_dir}" in text,
                f"Expected CMUX_PANE_CWD in terminal output: {text!r}",
            )
            _must(
                f"pwd={workspace_dir}" in text,
                f"Expected command to run in {workspace_dir}, got {text!r}",
            )

            client.select_workspace(baseline_workspace)
        finally:
            if created_workspace:
                try:
                    client.close_workspace(created_workspace)
                except Exception:
                    pass
            if previous_keybindings is not None or KEYBINDINGS_PATH.exists():
                _restore_keybindings_config(previous_keybindings)
            shutil.rmtree(workspace_dir, ignore_errors=True)

    print("PASS: custom command shortcut creates a new split and runs the command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
