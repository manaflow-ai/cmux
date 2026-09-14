#!/usr/bin/env python3
"""Run against an isolated tagged app: CMUX_TAG=<tag> python3 tests_v2/test_gui_mode_return.py."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


def main() -> None:
    if not os.environ.get("CMUX_TAG"):
        raise RuntimeError("CMUX_TAG must identify an isolated debug app")
    helper = Path(__file__).resolve().parents[1] / "scripts/cmux-debug-cli.sh"

    def rpc(method: str, params: dict | None = None) -> dict:
        result = subprocess.run(
            [str(helper), "rpc", method, json.dumps(params or {})],
            capture_output=True, text=True, timeout=30, check=True,
        )
        return json.loads(result.stdout)

    rpc("debug.app.activate")
    rpc("debug.shortcut.simulate", {"combo": "cmd+alt+shift+g"})
    # Rendering waits for the webview's snapshot and exercises the GUI that was
    # just opened. Return with the webview itself focused must not recursively
    # re-enter AppKit's key-equivalent routing, even without editor focus.
    rpc("debug.window.screenshot", {"label": "gui-return-before"})
    for combo in ("enter", "shift+enter", "enter"):
        rpc("debug.shortcut.simulate", {"combo": combo})
        rpc("debug.window.screenshot", {"label": "gui-return-after"})
    print("PASS: GUI Return/Shift-Return keep the app responsive")


if __name__ == "__main__":
    main()
