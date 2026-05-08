#!/usr/bin/env python3
"""CMX backend smoke: new workspace accepts incremental tabs and splits."""

from __future__ import annotations

import base64
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(fn, timeout_s: float = 10.0, step_s: float = 0.1):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        try:
            value = fn()
            if value:
                return value
        except Exception as exc:
            last = exc
        time.sleep(step_s)
    raise cmuxError(f"Timed out waiting for condition; last={last!r}")


def _text_from_payload(payload: dict) -> str:
    if "text" in payload:
        return str(payload.get("text") or "")
    b64 = str(payload.get("base64") or "")
    raw = base64.b64decode(b64) if b64 else b""
    return raw.decode("utf-8", errors="replace")


def _read_surface_text(c: cmux, surface_id: str, lines: int = 80) -> str:
    payload = c._call(
        "surface.read_text",
        {"surface_id": surface_id, "scrollback": True, "lines": lines},
    ) or {}
    return _text_from_payload(payload)


def _layout(c: cmux) -> dict:
    payload = c._call("debug.layout") or {}
    return dict(payload.get("layout") or payload)


def _layout_with_cursor(c: cmux, expected_style: str) -> dict:
    def probe() -> dict | None:
        layout = _layout(c)
        cursor = layout.get("terminalCursor") or {}
        if cursor.get("style") == expected_style:
            return layout
        return None

    return _wait_for(probe, timeout_s=10.0)


def _layout_workspace(layout: dict, workspace_id: str) -> dict:
    rows = ((layout.get("workspaces") or {}).get("workspaces") or [])
    for row in rows:
        if row.get("id") == workspace_id or row.get("workspace_id") == workspace_id:
            return dict(row)
    return {}


def _pane_surface_counts(c: cmux, workspace_id: str) -> list[int]:
    panes = (c._call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
    return sorted(int(row.get("surface_count") or row.get("tabCount") or 0) for row in panes)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities()
        if caps.get("backend") != "cmx-rust":
            print("SKIP: desktop CMX backend is not active")
            return 0

        native = caps.get("nativeBridge") or {}
        _must(native.get("connected") is True, f"native bridge is not connected: {native}")

        baseline = c.current_workspace()
        workspace_id = ""
        try:
            created = c._call(
                "workspace.create",
                {"title": "desktop-cmx-workspace-split-tab", "focus": True},
            ) or {}
            workspace_id = str(created.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
            c.select_workspace(workspace_id)
            _wait_for(lambda: c.current_workspace() == workspace_id)

            first_surfaces = _wait_for(
                lambda: (c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
            )
            _must(len(first_surfaces) == 1, f"new workspace should start with one surface: {first_surfaces}")
            first_surface = str(first_surfaces[0].get("id") or "")
            _must(bool(first_surface), f"initial surface missing id: {first_surfaces[0]}")

            same_pane_tab = (
                c._call(
                    "surface.create",
                    {"workspace_id": workspace_id, "type": "terminal", "focus": True},
                )
                or {}
            ).get("surface_id")
            _must(bool(same_pane_tab), "surface.create returned no surface_id")

            split_surface = (
                c._call(
                    "surface.split",
                    {
                        "workspace_id": workspace_id,
                        "surface_id": str(same_pane_tab),
                        "direction": "right",
                        "focus": True,
                    },
                )
                or {}
            ).get("surface_id")
            _must(bool(split_surface), "surface.split returned no surface_id")

            _wait_for(lambda: _pane_surface_counts(c, workspace_id) == [1, 2])
            surfaces = _wait_for(
                lambda: (c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
            )
            _must(len(surfaces) == 3, f"expected three terminal surfaces, got {surfaces}")
            _must(
                {str(row.get("type") or row.get("kind")) for row in surfaces} == {"terminal"},
                f"expected terminal-only workspace, got {surfaces}",
            )

            expected_cursor_style = os.environ.get("CMUX_TESTS_V2_EXPECT_CURSOR_STYLE", "bar")
            expected_cursor_blink = os.environ.get("CMUX_TESTS_V2_EXPECT_CURSOR_BLINK", "false").lower()
            layout = _layout_with_cursor(c, expected_cursor_style)
            layout_workspace = _layout_workspace(layout, workspace_id)
            _must(layout_workspace.get("spaceCount") == 1, f"expected one default space: {layout_workspace}")
            _must(layout_workspace.get("tabCount") == 3, f"layout tab count mismatch: {layout_workspace}")
            _must(layout_workspace.get("terminalCount") == 3, f"layout terminal count mismatch: {layout_workspace}")
            cursor = layout.get("terminalCursor") or {}
            _must(cursor.get("style") == expected_cursor_style, f"cursor style mismatch: {layout}")
            if expected_cursor_blink in {"true", "false"}:
                _must(
                    cursor.get("blink") == (expected_cursor_blink == "true"),
                    f"cursor blink mismatch: {layout}",
                )

            marker = "CMX_WORKSPACE_SPLIT_TAB_OK"
            c._call("surface.send_text", {"surface_id": str(split_surface), "text": f"echo {marker}\n"})
            _wait_for(lambda: marker in _read_surface_text(c, str(split_surface)), timeout_s=12.0)
        finally:
            if baseline:
                try:
                    c.select_workspace(baseline)
                except Exception:
                    pass
            if workspace_id:
                try:
                    c.close_workspace(workspace_id)
                except Exception as exc:
                    print(f"WARN: failed to close workspace {workspace_id}: {exc}", file=sys.stderr)

    print("PASS: CMX workspace split/tab creation matches layout and terminal behavior")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
