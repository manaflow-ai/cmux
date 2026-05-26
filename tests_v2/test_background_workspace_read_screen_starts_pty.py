#!/usr/bin/env python3
"""Regression: read-screen should start a plain background workspace PTY on demand."""

from __future__ import annotations

import glob
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Tuple

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

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: List[str], check: bool = True) -> Tuple[int, str]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    merged = f"{proc.stdout}\n{proc.stderr}".strip()
    if check and proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.returncode, proc.stdout.strip() if proc.returncode == 0 else merged


def _extract_ref(output: str, kind: str) -> str:
    match = re.search(rf"\b{kind}:\d+\b", output)
    if not match:
        raise cmuxError(f"Could not find {kind} ref in CLI output: {output!r}")
    return match.group(0)


def _wait_for_read_screen(cli: str, workspace_ref: str, surface_ref: str, token: str) -> str:
    deadline = time.time() + 8.0
    last_output = ""
    while time.time() < deadline:
        code, output = _run_cli(
            cli,
            [
                "read-screen",
                "--workspace",
                workspace_ref,
                "--surface",
                surface_ref,
                "--scrollback",
                "--lines",
                "80",
            ],
            check=False,
        )
        last_output = output
        if code == 0 and token in output:
            return output
        time.sleep(0.1)
    raise cmuxError(f"read-screen never observed {token!r} for {surface_ref}: {last_output!r}")


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        baseline = c._call("workspace.current") or {}
        baseline_ws = str(baseline.get("workspace_ref") or baseline.get("workspace_id") or "")
        _must(bool(baseline_ws), f"workspace.current returned no workspace_id: {baseline}")

        workspace_ref = ""
        try:
            _, create_output = _run_cli(cli, ["new-workspace", "--focus", "false"])
            workspace_ref = create_output.removeprefix("OK ").strip()
            _must(bool(workspace_ref), f"new-workspace returned no workspace ref: {create_output!r}")

            current = c._call("workspace.current") or {}
            _must(
                str(current.get("workspace_ref") or current.get("workspace_id") or "") == baseline_ws,
                f"new-workspace --focus false should preserve selected workspace: {current}",
            )

            _, surface_output = _run_cli(cli, ["list-pane-surfaces", "--workspace", workspace_ref])
            surface_ref = _extract_ref(surface_output, "surface")

            code, read_output = _run_cli(
                cli,
                [
                    "read-screen",
                    "--workspace",
                    workspace_ref,
                    "--surface",
                    surface_ref,
                    "--scrollback",
                    "--lines",
                    "80",
                ],
                check=False,
            )
            _must(
                code == 0,
                f"read-screen should demand-start the background PTY instead of failing: {read_output!r}",
            )
            _must(
                "Terminal surface not found" not in read_output and "Surface not ready" not in read_output,
                f"read-screen returned a stale readiness error: {read_output!r}",
            )

            token = f"CMUX_BG_READ_START_{time.time_ns()}"
            _run_cli(cli, ["send", "--workspace", workspace_ref, "--surface", surface_ref, "--", f"echo {token}"])
            _run_cli(cli, ["send-key", "--workspace", workspace_ref, "--surface", surface_ref, "enter"])

            text = _wait_for_read_screen(cli, workspace_ref, surface_ref, token)
            _must(token in text, f"background PTY did not execute command after send-key: {text!r}")

            current = c._call("workspace.current") or {}
            _must(
                str(current.get("workspace_ref") or current.get("workspace_id") or "") == baseline_ws,
                f"read-screen/send-key should not switch selected workspace: {current}",
            )
        finally:
            if workspace_ref:
                try:
                    c.close_workspace(workspace_ref)
                except Exception:
                    pass

    print("PASS: background workspace read-screen demand-starts PTY without focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
