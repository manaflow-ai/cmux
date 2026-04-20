#!/usr/bin/env python3
"""Regression: `cmux ssh` creates by default and only attaches explicitly."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
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


def _run_cli(cli: str, args: list[str], *, json_output: bool) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH]
    if json_output:
        cmd.append("--json")
    cmd.extend(args)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _run_cli_json(cli: str, args: list[str]) -> dict:
    output = _run_cli(cli, args, json_output=True)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _resolve_workspace_id_from_payload(client: cmux, payload: dict) -> str:
    workspace_id = str(payload.get("workspace_id") or "")
    if workspace_id:
        return workspace_id

    workspace_ref = str(payload.get("workspace_ref") or "")
    if not workspace_ref.startswith("workspace:"):
        return ""

    listed = client._call("workspace.list", {}) or {}
    for row in listed.get("workspaces") or []:
        if str(row.get("ref") or "") == workspace_ref:
            return str(row.get("id") or "")
    return ""


def _workspace_count(client: cmux) -> int:
    listed = client._call("workspace.list", {}) or {}
    return len(listed.get("workspaces") or [])


def main() -> int:
    cli = _find_cli_binary()
    help_text = _run_cli(cli, ["ssh", "--help"], json_output=False)
    _must("Create a new remote SSH workspace" in help_text, "ssh --help output should describe default creation")
    _must("Create or reuse" not in help_text, "ssh --help output should not advertise implicit reuse")
    _must("--attach" in help_text, "ssh --help output should document explicit attach")
    _must("--new" in help_text, "ssh --help output should document --new")

    workspaces_to_close: list[str] = []
    with cmux(SOCKET_PATH) as client:
        try:
            selected_before_setup = client.current_workspace()

            # Create a workspace configured as remote but NOT connected (auto_connect=False).
            disconnected_workspace_id = client.new_workspace()
            workspaces_to_close.append(disconnected_workspace_id)
            client._call(
                "workspace.remote.configure",
                {
                    "workspace_id": disconnected_workspace_id,
                    "destination": "cmux-reuse.test",
                    "port": 2200,
                    "auto_connect": False,
                },
            )
            client.select_workspace(selected_before_setup)

            # Verify disconnected workspaces are NOT reused — cmux ssh should
            # create a new workspace instead of attaching to a stale session.
            count_before = _workspace_count(client)
            selected_before = client.current_workspace()
            new_payload = _run_cli_json(
                cli,
                ["ssh", "cmux-reuse.test", "--port", "2200", "--no-focus"],
            )
            new_workspace_id = _resolve_workspace_id_from_payload(client, new_payload)
            if new_workspace_id:
                workspaces_to_close.append(new_workspace_id)

            _must(
                bool(new_payload.get("reused")) is False,
                f"disconnected workspace should not be reused: {new_payload}",
            )
            _must(
                not new_workspace_id or new_workspace_id != disconnected_workspace_id,
                f"cmux ssh should create a new workspace, not reuse disconnected {disconnected_workspace_id}: {new_payload}",
            )
            _must(
                _workspace_count(client) == count_before + 1,
                f"cmux ssh should create a new workspace when existing one is disconnected: before={count_before} payload={new_payload}",
            )
            _must(
                client.current_workspace() == selected_before,
                "cmux ssh --no-focus should not switch workspace",
            )

            # --new should always create a new workspace regardless.
            count_before_new = _workspace_count(client)
            force_new_payload = _run_cli_json(
                cli,
                ["ssh", "cmux-reuse.test", "--port", "2200", "--new", "--no-focus"],
            )
            force_new_workspace_id = _resolve_workspace_id_from_payload(client, force_new_payload)
            if force_new_workspace_id:
                workspaces_to_close.append(force_new_workspace_id)

            _must(bool(force_new_payload.get("reused")) is False, f"--new payload should set reused=false: {force_new_payload}")
            _must(
                bool(force_new_workspace_id) and force_new_workspace_id != disconnected_workspace_id,
                f"cmux ssh --new should create a distinct workspace: existing={disconnected_workspace_id} payload={force_new_payload}",
            )
            _must(
                _workspace_count(client) == count_before_new + 1,
                f"cmux ssh --new should create exactly one workspace: before={count_before_new} payload={force_new_payload}",
            )
        finally:
            for workspace_id in dict.fromkeys(workspaces_to_close):
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: cmux ssh creates by default and reserves reuse for explicit attach")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
