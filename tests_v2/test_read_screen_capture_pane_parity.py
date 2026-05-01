#!/usr/bin/env python3
"""Regression: capture-pane parity via production read-screen APIs."""

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


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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
        _must("surface.read_text" in methods, f"Missing surface.read_text in capabilities: {sorted(methods)[:20]}")

        created_target = c._call("workspace.create") or {}
        ws_target = str(created_target.get("workspace_id") or "")
        _must(bool(ws_target), f"workspace.create returned no workspace_id: {created_target}")
        c._call("workspace.select", {"workspace_id": ws_target})

        surfaces_payload = c._call("surface.list", {"workspace_id": ws_target}) or {}
        surfaces = surfaces_payload.get("surfaces") or []
        _must(bool(surfaces), f"Expected at least one surface in workspace: {surfaces_payload}")
        surface_target = str(surfaces[0].get("id") or "")
        _must(bool(surface_target), f"surface.list returned surface without id: {surfaces_payload}")

        created_other = c._call("workspace.create") or {}
        ws_other = str(created_other.get("workspace_id") or "")
        _must(bool(ws_other), f"workspace.create returned no workspace_id: {created_other}")
        c._call("workspace.select", {"workspace_id": ws_other})

        selected = c._call("workspace.current") or {}
        _must(str(selected.get("workspace_id") or "") == ws_other, f"Expected selected workspace {ws_other}, got: {selected}")

        token = f"CMUX_READ_SCREEN_{int(time.time() * 1000)}"
        c._call("surface.send_text", {
            "workspace_id": ws_target,
            "surface_id": surface_target,
            "text": f"echo {token}\n",
        })

        def has_token() -> bool:
            payload = c._call("surface.read_text", {"workspace_id": ws_target, "surface_id": surface_target}) or {}
            return token in str(payload.get("text") or "")

        _wait_for(has_token, timeout_s=5.0)

        read_payload = c._call("surface.read_text", {"workspace_id": ws_target, "surface_id": surface_target}) or {}
        text = str(read_payload.get("text") or "")
        _must(token in text, f"surface.read_text missing token {token!r}: {read_payload}")

        ws_only_payload = c._call("surface.read_text", {"workspace_id": ws_target}) or {}
        _must(token in str(ws_only_payload.get("text") or ""), f"surface.read_text workspace-only call missing token {token!r}: {ws_only_payload}")

        cli_text = _run_cli(cli, ["read-screen", "--workspace", ws_target, "--surface", surface_target])
        _must(token in cli_text, f"cmux read-screen output missing token {token!r}: {cli_text!r}")

        cli_ws_only = _run_cli(cli, ["read-screen", "--workspace", ws_target])
        _must(token in cli_ws_only, f"cmux read-screen --workspace output missing token {token!r}: {cli_ws_only!r}")

        cli_text_scrollback = _run_cli(cli, ["read-screen", "--workspace", ws_target, "--surface", surface_target, "--scrollback", "--lines", "80"])
        _must(token in cli_text_scrollback, f"cmux read-screen --scrollback output missing token {token!r}: {cli_text_scrollback!r}")

        color_token = f"CMUX_VT_READ_{int(time.time() * 1000)}"
        c._call("surface.send_text", {
            "workspace_id": ws_target,
            "surface_id": surface_target,
            "text": f"printf '\\033[31m%s\\033[0m\\n' {color_token}\n",
        })

        def has_color_token() -> bool:
            payload = c._call("surface.read_text", {
                "workspace_id": ws_target,
                "surface_id": surface_target,
                "lines": 80,
            }) or {}
            return color_token in str(payload.get("text") or "")

        _wait_for(has_color_token, timeout_s=5.0)

        vt_payload = c._call("surface.read_text", {
            "workspace_id": ws_target,
            "surface_id": surface_target,
            "format": "vt",
            "lines": 80,
        }) or {}
        vt_text = str(vt_payload.get("text") or "")
        _must(vt_payload.get("format") == "vt", f"surface.read_text format=vt lines=80 did not return vt format: {vt_payload}")
        _must(color_token in vt_text, f"surface.read_text format=vt lines=80 missing token {color_token!r}: {vt_payload}")
        _must("\x1b[" in vt_text, f"surface.read_text format=vt lines=80 missing ANSI escapes: {vt_payload}")

        history_token = f"CMUX_VT_HISTORY_{int(time.time() * 1000)}"
        screen_token = f"CMUX_VT_SCREEN_{int(time.time() * 1000)}"
        c._call("surface.send_text", {
            "workspace_id": ws_target,
            "surface_id": surface_target,
            "text": (
                f"printf '\\033[32m%s\\033[0m\\n' {history_token}; "
                "i=0; while [ $i -lt 160 ]; do echo CMUX_VT_FILLER_$i; i=$((i + 1)); done; "
                f"printf '\\033[34m%s\\033[0m\\n' {screen_token}\n"
            ),
        })

        def has_screen_token() -> bool:
            payload = c._call("surface.read_text", {
                "workspace_id": ws_target,
                "surface_id": surface_target,
                "lines": 80,
            }) or {}
            return screen_token in str(payload.get("text") or "")

        _wait_for(has_screen_token, timeout_s=5.0)

        vt_scrollback_payload = c._call("surface.read_text", {
            "workspace_id": ws_target,
            "surface_id": surface_target,
            "format": "vt",
            "scrollback": True,
        }) or {}
        vt_scrollback_text = str(vt_scrollback_payload.get("text") or "")
        _must(vt_scrollback_payload.get("format") == "vt", f"surface.read_text format=vt scrollback did not return vt format: {vt_scrollback_payload}")
        _must(history_token in vt_scrollback_text, f"surface.read_text format=vt scrollback missing history token {history_token!r}: {vt_scrollback_payload}")
        _must(screen_token in vt_scrollback_text, f"surface.read_text format=vt scrollback missing active screen token {screen_token!r}: {vt_scrollback_payload}")
        _must("\x1b[" in vt_scrollback_text, f"surface.read_text format=vt scrollback missing ANSI escapes: {vt_scrollback_payload}")

        cli_json = _run_cli(cli, ["--json", "read-screen", "--workspace", ws_target, "--surface", surface_target])
        payload = json.loads(cli_json or "{}")
        _must(token in str(payload.get("text") or ""), f"cmux --json read-screen missing token {token!r}: {payload}")

        invalid = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "read-screen", "--workspace", ws_target, "--surface", surface_target, "--lines", "0"],
            capture_output=True,
            text=True,
            check=False,
        )
        invalid_output = f"{invalid.stdout}\n{invalid.stderr}"
        _must(invalid.returncode != 0, "Expected read-screen --lines 0 to fail")
        _must("--lines must be greater than 0" in invalid_output, f"Unexpected error for --lines 0: {invalid_output!r}")

    print("PASS: production read-screen APIs expose capture-pane behavior")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
