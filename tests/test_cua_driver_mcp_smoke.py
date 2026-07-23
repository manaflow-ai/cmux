#!/usr/bin/env python3
"""
Optional smoke test for the bundled cmux-cua-driver MCP server.

The test uses a real built driver binary when present and skips otherwise.
It performs only MCP initialize + tools/list, with no GUI actions.
"""

from __future__ import annotations

import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE_TOOLS = {"get_window_state", "click", "scroll", "zoom"}


def candidate_binaries() -> list[Path]:
    candidates: list[Path] = []
    for env_key in ("CMUX_CUA_DRIVER", "CMUX_CUA_DRIVER_BIN"):
        value = os.environ.get(env_key)
        if value:
            candidates.append(Path(value))
    # Only explicit env overrides and repo/build-output paths are eligible.
    # Never probe predictable world-writable locations like /tmp: anyone on
    # the machine could pre-plant an executable there and this test would run
    # it with the caller's credentials.
    candidates.extend(
        [
            ROOT / "Resources" / "bin" / "cmux-cua-driver",
            ROOT / "build-universal" / "Build" / "Products" / "Release" / "cmux.app" / "Contents" / "Resources" / "bin" / "cmux-cua-driver",
        ]
    )
    derived_data = os.environ.get("CMUX_DERIVED_DATA_PATH")
    if derived_data:
        candidates.extend(Path(derived_data).glob("Build/Products/*/*.app/Contents/Resources/bin/cmux-cua-driver"))
    return candidates


def find_driver() -> Path | None:
    for candidate in candidate_binaries():
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def read_json_line(proc: subprocess.Popen[str], timeout: float = 15.0) -> dict:
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        events = selector.select(timeout)
        if not events:
            raise TimeoutError("timed out waiting for cua-driver MCP response")
        line = proc.stdout.readline()
    finally:
        selector.close()
    if not line:
        raise RuntimeError("cua-driver exited before writing an MCP response")
    return json.loads(line)


def send(proc: subprocess.Popen[str], payload: dict) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def main() -> int:
    driver = find_driver()
    if driver is None:
        print("SKIP: cmux-cua-driver binary not built; run scripts/build-cua-driver.sh first")
        return 0

    env = os.environ.copy()
    env["CUA_DRIVER_EMBEDDED"] = "1"
    env["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "false"
    # Keep the smoke test hermetic: without this the driver's startup update
    # checker contacts GitHub and writes ~/.cua-driver-rs/version_check.json.
    env["CUA_DRIVER_RS_UPDATE_CHECK"] = "false"
    # Isolated HOME so nothing the driver writes lands in the real home.
    home = tempfile.mkdtemp(prefix="cua-smoke-home-")
    env["HOME"] = home
    proc = subprocess.Popen(
        [str(driver), "--embedded", "--no-overlay"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "cmux-smoke", "version": "1"},
                },
            },
        )
        init_resp = read_json_line(proc)
        if init_resp.get("error"):
            raise AssertionError(f"initialize returned error: {init_resp}")
        if init_resp.get("result", {}).get("serverInfo", {}).get("name") not in {"cua-driver", "cmux-computer-use"}:
            raise AssertionError(f"unexpected initialize serverInfo: {init_resp}")

        send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        list_resp = read_json_line(proc)
        if list_resp.get("error"):
            raise AssertionError(f"tools/list returned error: {list_resp}")
        tools = list_resp.get("result", {}).get("tools", [])
        names = {tool.get("name") for tool in tools}
        missing = sorted(CORE_TOOLS - names)
        if missing:
            raise AssertionError(f"missing core tools {missing}; listed {sorted(name for name in names if name)}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        if proc.stderr is not None:
            # Drain stderr so the pipe cannot leak into a later test process.
            try:
                proc.stderr.read()
            except Exception:
                pass
        shutil.rmtree(home, ignore_errors=True)

    print(f"PASS: cua-driver MCP smoke ({driver})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
