#!/usr/bin/env python3
"""Regression: tab/workspace action naming is consistent in CLI + socket v2."""

import glob
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List

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


def _run_cli(cli: str, args: List[str], json_output: bool) -> str:
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


def _run_cli_json(cli: str, args: List[str]) -> Dict:
    output = _run_cli(cli, args, json_output=True)
    try:
        return json.loads(output or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {output!r} ({exc})")


def _focused_surface_ref(c: cmux, workspace_id: str) -> str:
    current = c._call("surface.current", {"workspace_id": workspace_id}) or {}
    surface_ref = str(current.get("surface_ref") or "")
    if surface_ref.startswith("surface:"):
        return surface_ref

    listed = c._call("surface.list", {"workspace_id": workspace_id}) or {}
    rows = listed.get("surfaces") or []
    for row in rows:
        if bool(row.get("focused")):
            ref = str(row.get("ref") or "")
            if ref.startswith("surface:"):
                return ref
    for row in rows:
        ref = str(row.get("ref") or "")
        if ref.startswith("surface:"):
            return ref

    raise cmuxError(f"Unable to resolve focused surface ref in workspace {workspace_id}: {listed}")


def main() -> int:
    cli = _find_cli_binary()

    help_text = _run_cli(cli, ["tab-action", "--help"], json_output=False)
    _must("Target tab" in help_text, "tab-action --help should describe tab target naming")
    _must("tab:<n>" in help_text, "tab-action --help should mention tab:<n> refs")
    _must("--tab tab:" in help_text, "tab-action examples should use tab: refs")

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        for method in ["workspace.action", "tab.action", "surface.action"]:
            _must(method in methods, f"Missing method in capabilities: {method}")

        created = c._call("workspace.create", {}) or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
        try:
            c._call("workspace.select", {"workspace_id": ws_id})

            surface_ref = _focused_surface_ref(c, ws_id)
            tab_ref = "tab:" + surface_ref.split(":", 1)[1]

            pin = _run_cli_json(cli, ["tab-action", "--workspace", ws_id, "--tab", tab_ref, "--action", "pin"])
            _must(str(pin.get("tab_ref") or "").startswith("tab:"), f"Expected tab_ref in tab-action payload: {pin}")
            _must(bool(pin.get("pinned")) is True, f"tab-action pin should report pinned=true: {pin}")

            unpin = _run_cli_json(cli, ["tab-action", "--workspace", ws_id, "--tab", tab_ref, "--action", "unpin"])
            _must(bool(unpin.get("pinned")) is False, f"tab-action unpin should report pinned=false: {unpin}")

            socket_tab = c._call("tab.action", {"workspace_id": ws_id, "tab_id": tab_ref, "action": "clear_name"}) or {}
            _must(str(socket_tab.get("tab_ref") or "").startswith("tab:"), f"Expected tab_ref in tab.action result: {socket_tab}")
            _must(str(socket_tab.get("workspace_id") or "") == ws_id, f"tab.action should target requested workspace: {socket_tab}")
        finally:
            try:
                c.close_workspace(ws_id)
            except Exception:
                pass

    print("PASS: tab/workspace naming stays consistent across tab-action CLI and socket APIs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
