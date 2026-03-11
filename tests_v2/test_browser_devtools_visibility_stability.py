#!/usr/bin/env python3
"""v2 regression: browser DevTools stays open after a single toggle."""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_until(pred, timeout_s: float, label: str) -> None:
    deadline = time.time() + timeout_s
    last_exc = None
    while time.time() < deadline:
        try:
            if pred():
                return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.05)
    if last_exc is not None:
        raise cmuxError(f"Timed out waiting for {label}: {last_exc}")
    raise cmuxError(f"Timed out waiting for {label}")


def _surface_row(c: cmux, workspace_id: str, surface_id: str) -> dict:
    payload = c._call("surface.list", {"workspace_id": workspace_id}) or {}
    for row in payload.get("surfaces") or []:
        if str(row.get("id") or "") == surface_id:
            return row
    raise cmuxError(f"surface.list missing surface {surface_id} in workspace {workspace_id}: {payload}")


def _devtools_visible(c: cmux, workspace_id: str, surface_id: str) -> bool:
    row = _surface_row(c, workspace_id, surface_id)
    return bool(row.get("developer_tools_visible"))


def _focus_browser_webview(c: cmux, surface_id: str, timeout_s: float = 2.0) -> None:
    deadline = time.time() + timeout_s
    last_exc = None
    while time.time() < deadline:
        try:
            c.focus_surface(surface_id)
            c.focus_webview(surface_id)
            if c.is_webview_focused(surface_id):
                return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for browser webview focus: {last_exc}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        workspace_id = c.new_workspace()
        try:
            c.select_workspace(workspace_id)
            time.sleep(0.3)

            surface_id = c.new_surface(panel_type="browser", url="https://example.com")
            _wait_until(
                lambda: _surface_row(c, workspace_id, surface_id).get("type") == "browser",
                timeout_s=5.0,
                label="browser surface in surface.list",
            )
            _focus_browser_webview(c, surface_id, timeout_s=3.0)

            _must(
                _devtools_visible(c, workspace_id, surface_id) is False,
                "Expected DevTools to start closed",
            )

            c.simulate_shortcut("cmd+opt+i")

            _wait_until(
                lambda: _devtools_visible(c, workspace_id, surface_id),
                timeout_s=3.0,
                label="DevTools visible after toggle",
            )

            deadline = time.time() + 1.5
            while time.time() < deadline:
                _must(
                    _devtools_visible(c, workspace_id, surface_id) is True,
                    "DevTools reopened/closed unexpectedly after initial open",
                )
                time.sleep(0.05)
        finally:
            try:
                c.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: browser DevTools stays open after a single toggle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
