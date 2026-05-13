#!/usr/bin/env python3
"""Regression: new workspace commands should execute without selecting the workspace."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import tempfile
import time
from contextlib import suppress
from pathlib import Path

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


def _run_cli(cli: str, args: list[str]) -> tuple[subprocess.CompletedProcess[str], float]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    started = time.monotonic()
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH] + args,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    elapsed = time.monotonic() - started
    return proc, elapsed


def _wait_for_marker(marker: Path, token: str, timeout_s: float = 12.0) -> str:
    observed = ""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if marker.exists():
            try:
                observed = marker.read_text(encoding="utf-8").strip()
            except OSError:
                observed = ""
            if observed == token:
                break
        time.sleep(0.05)

    _must(marker.exists(), f"Command marker file was not created: {marker}")
    _must(observed == token, f"Queued command did not execute as expected: expected={token!r} observed={observed!r}")
    return observed


def main() -> int:
    cli = _find_cli_binary()
    marker = Path(tempfile.gettempdir()) / f"cmux_new_workspace_command_{os.getpid()}.txt"
    layout_left_marker = Path(tempfile.gettempdir()) / f"cmux_new_workspace_layout_left_{os.getpid()}.txt"
    layout_right_marker = Path(tempfile.gettempdir()) / f"cmux_new_workspace_layout_right_{os.getpid()}.txt"
    created_ws_id: str | None = None
    created_layout_ws_id: str | None = None

    for path in (marker, layout_left_marker, layout_right_marker):
        with suppress(OSError):
            path.unlink(missing_ok=True)

    with cmux(SOCKET_PATH) as c:
        try:
            baseline_ws_id = c.current_workspace()
            token = f"queued-{os.getpid()}-{int(time.time() * 1000)}"
            cmd_text = f"echo {token} > {marker}"

            proc, elapsed = _run_cli(cli, ["new-workspace", "--command", cmd_text])
            combined = f"{proc.stdout}\n{proc.stderr}".strip()
            _must(proc.returncode == 0, f"CLI failed ({proc.returncode}): {combined}")
            _must(elapsed < 1.5, f"new-workspace --command should return quickly, took {elapsed:.2f}s")

            output = (proc.stdout or "").strip()
            _must(output.startswith("OK "), f"Expected OK response, got: {output!r}")
            _must("Surface not ready" not in combined, f"Unexpected surface readiness error: {combined}")
            created_ws_id = output[3:].strip()
            _must(bool(created_ws_id), f"Missing workspace id in output: {output!r}")

            # Creation with --command should not steal focus.
            _must(c.current_workspace() == baseline_ws_id, "new-workspace --command should preserve selected workspace")

            _wait_for_marker(marker, token)
            _must(c.current_workspace() == baseline_ws_id, "Command execution should not switch selected workspace")

            layout_left_token = f"layout-left-{os.getpid()}-{int(time.time() * 1000)}"
            layout_right_token = f"layout-right-{os.getpid()}-{int(time.time() * 1000)}"
            layout = {
                "direction": "horizontal",
                "split": 0.5,
                "children": [
                    {
                        "pane": {
                            "surfaces": [
                                {
                                    "type": "terminal",
                                    "command": f"echo {layout_left_token} > {layout_left_marker}",
                                }
                            ]
                        }
                    },
                    {
                        "pane": {
                            "surfaces": [
                                {
                                    "type": "terminal",
                                    "command": f"echo {layout_right_token} > {layout_right_marker}",
                                }
                            ]
                        }
                    },
                ],
            }
            proc, elapsed = _run_cli(
                cli,
                [
                    "new-workspace",
                    "--name",
                    "command-layout-queue",
                    "--cwd",
                    tempfile.gettempdir(),
                    "--layout",
                    json.dumps(layout, separators=(",", ":")),
                ],
            )
            combined = f"{proc.stdout}\n{proc.stderr}".strip()
            _must(proc.returncode == 0, f"CLI layout create failed ({proc.returncode}): {combined}")
            _must(elapsed < 1.5, f"new-workspace --layout should return quickly, took {elapsed:.2f}s")

            output = (proc.stdout or "").strip()
            _must(output.startswith("OK "), f"Expected OK response for layout create, got: {output!r}")
            created_layout_ws_id = output[3:].strip()
            _must(bool(created_layout_ws_id), f"Missing layout workspace id in output: {output!r}")
            _must(c.current_workspace() == baseline_ws_id, "new-workspace --layout should preserve selected workspace")

            _wait_for_marker(layout_left_marker, layout_left_token)
            _wait_for_marker(layout_right_marker, layout_right_token)
            _must(c.current_workspace() == baseline_ws_id, "Layout command execution should not switch selected workspace")
        finally:
            with suppress(Exception):
                if created_layout_ws_id:
                    c.close_workspace(created_layout_ws_id)
            with suppress(Exception):
                if created_ws_id:
                    c.close_workspace(created_ws_id)

    for path in (marker, layout_left_marker, layout_right_marker):
        with suppress(OSError):
            path.unlink(missing_ok=True)

    print("PASS: new-workspace --command and --layout commands execute without opening the created workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
