#!/usr/bin/env python3
"""Regression: workspace.create must apply initial_env to the initial terminal."""

import os
import sys
import time
import base64
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_text(c: cmux, workspace_id: str, needle: str, timeout_s: float = 8.0) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        payload = c._call(
            "surface.read_text",
            {"workspace_id": workspace_id},
        ) or {}
        if "text" in payload:
            last_text = str(payload.get("text") or "")
        else:
            b64 = str(payload.get("base64") or "")
            raw = base64.b64decode(b64) if b64 else b""
            last_text = raw.decode("utf-8", errors="replace")
        if needle in last_text:
            return last_text
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r} in panel text: {last_text!r}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        baseline_workspace = c.current_workspace()
        created_workspace = ""
        try:
            token = f"tok_{int(time.time() * 1000)}"
            payload = c._call(
                "workspace.create",
                {
                    "initial_env": {"CMUX_INITIAL_ENV_TOKEN": token},
                },
            ) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")
            _must(c.current_workspace() == baseline_workspace, "workspace.create should not steal workspace focus")

            # Terminal surfaces in background workspaces may not be attached/render-ready yet.
            # Select it before reading text so the initial command output is available.
            c.select_workspace(created_workspace)
            listed = c._call("surface.list", {"workspace_id": created_workspace}) or {}
            rows = list(listed.get("surfaces") or [])
            _must(bool(rows), "Expected at least one surface in the created workspace")
            terminal_row = next((row for row in rows if str(row.get("type") or "") == "terminal"), None)
            _must(terminal_row is not None, f"Expected a terminal surface in workspace.create result: {rows}")

            c.send("printf 'CMUX_ENV_CHECK=%s\\n' \"$CMUX_INITIAL_ENV_TOKEN\"\\n")
            text = _wait_for_text(c, created_workspace, f"CMUX_ENV_CHECK={token}")
            _must(
                f"CMUX_ENV_CHECK={token}" in text,
                f"initial_env token missing from terminal output: {text!r}",
            )
            c.select_workspace(baseline_workspace)
        finally:
            if created_workspace:
                try:
                    c.close_workspace(created_workspace)
                except Exception:
                    pass

    print("PASS: workspace.create applies initial_env to initial terminal")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
