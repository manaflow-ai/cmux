#!/usr/bin/env python3
"""
Regression test: app shortcuts must apply to the focused window only.

Covers:
- Cmd+B (toggle sidebar) should only affect the active window.
- Cmd+T (new terminal tab/surface) should only affect the active window.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 4.0, interval_s: float = 0.05, message: str = "timeout") -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise cmuxError(message)


def _sidebar_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.sidebar.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def _surface_count(client: cmux, workspace_id: str) -> int:
    payload = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    return len(payload.get("surfaces") or [])


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        time.sleep(0.2)

        window_a = client.current_window()
        window_b = client.new_window()
        time.sleep(0.25)

        workspace_a = client.new_workspace(window_id=window_a)
        workspace_b = client.new_workspace(window_id=window_b)
        time.sleep(0.25)

        client.focus_window(window_a)
        client.activate_app()
        time.sleep(0.2)

        a_before = _sidebar_visible(client, window_a)
        b_before = _sidebar_visible(client, window_b)

        client.simulate_shortcut("cmd+b")
        _wait_until(
            lambda: _sidebar_visible(client, window_a) != a_before,
            message="Cmd+B did not toggle sidebar in active window A",
        )
        a_after = _sidebar_visible(client, window_a)
        b_after = _sidebar_visible(client, window_b)
        if b_after != b_before:
            raise cmuxError("Cmd+B in window A incorrectly toggled sidebar in window B")

        client.focus_window(window_b)
        client.activate_app()
        time.sleep(0.2)

        client.simulate_shortcut("cmd+b")
        _wait_until(
            lambda: _sidebar_visible(client, window_b) != b_after,
            message="Cmd+B did not toggle sidebar in active window B",
        )
        if _sidebar_visible(client, window_a) != a_after:
            raise cmuxError("Cmd+B in window B incorrectly toggled sidebar in window A")

        client.focus_window(window_a)
        client.activate_app()
        time.sleep(0.2)
        client.select_workspace(workspace_a)
        time.sleep(0.1)

        count_a_before = _surface_count(client, workspace_a)
        count_b_before = _surface_count(client, workspace_b)

        client.simulate_shortcut("cmd+t")
        _wait_until(
            lambda: _surface_count(client, workspace_a) == count_a_before + 1,
            message="Cmd+T did not create a new surface in active window A",
        )

        count_b_after = _surface_count(client, workspace_b)
        if count_b_after != count_b_before:
            raise cmuxError("Cmd+T in window A incorrectly created a surface in window B")

    print("PASS: window-scoped shortcuts stay in the active window (Cmd+B, Cmd+T)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
