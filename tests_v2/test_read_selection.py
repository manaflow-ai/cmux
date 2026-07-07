#!/usr/bin/env python3
"""End-to-end: surface.read_selection socket method + `cmux read-screen --selection`.

Selection is created without mouse input via the DEBUG-only
`debug.terminal.select_all` hook (selects the surface's entire screen through
the `select_all` binding action).
"""

import base64
import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred: Callable[[], bool], timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


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


def _run_cli(cli: str, args: List[str]) -> str:
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must("surface.read_selection" in methods, f"Missing surface.read_selection in capabilities: {sorted(methods)[:20]}")

        created = c._call("workspace.create") or {}
        ws = str(created.get("workspace_id") or "")
        _must(bool(ws), f"workspace.create returned no workspace_id: {created}")
        c._call("workspace.select", {"workspace_id": ws})

        surfaces_payload = c._call("surface.list", {"workspace_id": ws}) or {}
        surfaces = surfaces_payload.get("surfaces") or []
        _must(bool(surfaces), f"Expected at least one surface in workspace: {surfaces_payload}")
        sf = str(surfaces[0].get("id") or "")
        _must(bool(sf), f"surface.list returned surface without id: {surfaces_payload}")

        # 1) Fresh terminal: no active selection.
        payload = c._call("surface.read_selection", {"workspace_id": ws, "surface_id": sf}) or {}
        _must(payload.get("has_selection") is False, f"Expected has_selection false on fresh terminal: {payload}")
        _must(str(payload.get("text") or "") == "", f"Expected empty text without selection: {payload}")

        # 2) CLI without selection: non-zero exit + explicit error.
        no_sel = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "read-screen", "--workspace", ws, "--surface", sf, "--selection"],
            capture_output=True,
            text=True,
            check=False,
        )
        _must(no_sel.returncode != 0, "Expected read-screen --selection to fail without a selection")
        _must("no active selection" in f"{no_sel.stdout}\n{no_sel.stderr}", f"Unexpected no-selection error: {no_sel.stderr!r}")

        # 3) --selection is incompatible with --scrollback/--lines.
        bad_combo = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "read-screen", "--workspace", ws, "--surface", sf, "--selection", "--scrollback"],
            capture_output=True,
            text=True,
            check=False,
        )
        _must(bad_combo.returncode != 0, "Expected --selection --scrollback to fail")
        _must("cannot be combined" in f"{bad_combo.stdout}\n{bad_combo.stderr}", f"Unexpected combo error: {bad_combo.stderr!r}")

        # 4) Put a token on screen, select all, and read the selection back.
        token = f"CMUX_READ_SELECTION_{int(time.time() * 1000)}"
        c._call("surface.send_text", {"workspace_id": ws, "surface_id": sf, "text": f"echo {token}\n"})

        def has_token() -> bool:
            read = c._call("surface.read_text", {"workspace_id": ws, "surface_id": sf}) or {}
            return token in str(read.get("text") or "")

        _wait_for(has_token, timeout_s=5.0)

        selected = c._call("debug.terminal.select_all", {"surface_id": sf}) or {}
        _must(selected.get("selected") is True, f"debug.terminal.select_all failed: {selected}")

        sel_payload = c._call("surface.read_selection", {"workspace_id": ws, "surface_id": sf}) or {}
        _must(sel_payload.get("has_selection") is True, f"Expected has_selection true after select_all: {sel_payload}")
        sel_text = str(sel_payload.get("text") or "")
        _must(token in sel_text, f"surface.read_selection missing token {token!r}: {sel_payload}")
        decoded = base64.b64decode(str(sel_payload.get("base64") or "")).decode("utf-8")
        _must(decoded == sel_text, "base64 payload does not round-trip to text")

        # 5) CLI --selection prints the selection.
        cli_sel = _run_cli(cli, ["read-screen", "--workspace", ws, "--surface", sf, "--selection"])
        _must(token in cli_sel, f"cmux read-screen --selection output missing token {token!r}: {cli_sel!r}")

        # 6) --json passes the payload through (has_selection + text).
        cli_json = json.loads(_run_cli(cli, ["--json", "read-screen", "--workspace", ws, "--surface", sf, "--selection"]) or "{}")
        _must(cli_json.get("has_selection") is True, f"--json missing has_selection: {cli_json}")
        _must(token in str(cli_json.get("text") or ""), f"--json missing token: {cli_json}")

        c.close_workspace(ws)

    print("PASS: surface.read_selection + read-screen --selection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
