#!/usr/bin/env python3
"""Regression: `new-workspace --command` should execute without selecting the workspace."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _float_env(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


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

    command = [cli, "--socket", SOCKET_PATH, *args]
    timeout = _float_env("CMUX_TEST_CLI_RUN_TIMEOUT", 30.0)
    started = time.monotonic()
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        details = f"stdout={exc.output!r} stderr={exc.stderr!r}"
        raise cmuxError(f"CLI timed out after {timeout:.1f}s: {command!r}; {details}") from exc
    elapsed = time.monotonic() - started
    return proc, elapsed


def main() -> int:
    cli = _find_cli_binary()
    marker = Path(tempfile.gettempdir()) / f"cmux_new_workspace_command_{os.getpid()}.txt"
    created_ws_id: str | None = None

    try:
        marker.unlink(missing_ok=True)
    except OSError:
        pass

    with cmux(SOCKET_PATH) as c:
        try:
            baseline_ws_id = c.current_workspace()
            token = f"queued-{os.getpid()}-{int(time.time() * 1000)}"
            cmd_text = f"echo {token} > {marker}"

            proc, elapsed = _run_cli(cli, ["new-workspace", "--command", cmd_text])
            combined = f"{proc.stdout}\n{proc.stderr}".strip()
            _must(proc.returncode == 0, f"CLI failed ({proc.returncode}): {combined}")
            quick_return_timeout = _float_env("NEW_WORKSPACE_COMMAND_TIMEOUT", 5.0)
            _must(
                elapsed < quick_return_timeout,
                f"new-workspace --command should return quickly, took {elapsed:.2f}s",
            )

            output = (proc.stdout or "").strip()
            _must(output.startswith("OK "), f"Expected OK response, got: {output!r}")
            _must("Surface not ready" not in combined, f"Unexpected surface readiness error: {combined}")
            created_ws_id = output[3:].strip()
            _must(bool(created_ws_id), f"Missing workspace id in output: {output!r}")

            # Creation with --command should not steal focus.
            _must(c.current_workspace() == baseline_ws_id, "new-workspace --command should preserve selected workspace")

            observed = ""
            deadline = time.time() + 12.0
            while time.time() < deadline:
                if marker.exists():
                    try:
                        observed = marker.read_text(encoding="utf-8").strip()
                    except OSError:
                        observed = ""
                    if observed:
                        break
                time.sleep(0.05)

            _must(marker.exists(), f"Command marker file was not created: {marker}")
            _must(observed == token, f"Queued command did not execute as expected: expected={token!r} observed={observed!r}")
            _must(c.current_workspace() == baseline_ws_id, "Command execution should not switch selected workspace")
        finally:
            if created_ws_id:
                try:
                    c.close_workspace(created_ws_id)
                except Exception:
                    pass

    try:
        marker.unlink(missing_ok=True)
    except OSError:
        pass

    print("PASS: new-workspace --command executes without opening the created workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
