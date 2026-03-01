#!/usr/bin/env python3
"""Regression: pane.resize preserves terminal content drawn before resize."""

from __future__ import annotations

import os
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


DEFAULT_SOCKET_PATHS = ["/tmp/cmux-debug.sock", "/tmp/cmux.sock"]


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred, timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _layout_panes(client: cmux) -> list[dict]:
    layout_payload = client.layout_debug() or {}
    layout = layout_payload.get("layout") or {}
    return list(layout.get("panes") or [])


def _pane_extent(client: cmux, pane_id: str, axis: str) -> float:
    panes = _layout_panes(client)
    for pane in panes:
        pid = str(pane.get("paneId") or pane.get("pane_id") or "")
        if pid != pane_id:
            continue
        frame = pane.get("frame") or {}
        return float(frame.get(axis) or 0.0)
    raise cmuxError(f"Pane {pane_id} missing from debug layout panes: {panes}")


def _pane_for_surface(client: cmux, surface_id: str) -> str:
    for _idx, pane_id, _count, _focused in client.list_panes():
        rows = client.list_pane_surfaces(pane_id)
        if any(sid == surface_id for _row_idx, sid, _title, _selected in rows):
            return pane_id
    raise cmuxError(f"Surface {surface_id} is not present in current workspace panes")


def _surface_scrollback_text(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
    ) or {}
    return str(payload.get("text") or "")


def _pick_resize_direction_for_pane(client: cmux, pane_ids: list[str], target_pane: str) -> tuple[str, str]:
    panes = [p for p in _layout_panes(client) if str(p.get("paneId") or p.get("pane_id") or "") in pane_ids]
    if len(panes) < 2:
        raise cmuxError(f"Need >=2 panes for resize test, got {panes}")

    def x_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("x") or 0.0)

    def y_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("y") or 0.0)

    x_span = max(x_of(p) for p in panes) - min(x_of(p) for p in panes)
    y_span = max(y_of(p) for p in panes) - min(y_of(p) for p in panes)

    if x_span >= y_span:
        left_pane = min(panes, key=x_of)
        left_id = str(left_pane.get("paneId") or left_pane.get("pane_id") or "")
        return ("right" if target_pane == left_id else "left"), "width"

    top_pane = min(panes, key=y_of)
    top_id = str(top_pane.get("paneId") or top_pane.get("pane_id") or "")
    return ("down" if target_pane == top_id else "up"), "height"


def _run_once(socket_path: str) -> int:
    workspace_id = ""
    try:
        with cmux(socket_path) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]

            stamp = secrets.token_hex(4)
            resize_lines = [f"CMUX_LOCAL_RESIZE_LINE_{stamp}_{index:02d}" for index in range(1, 33)]
            clear_and_draw = "printf '\\033[2J\\033[H'; " + "; ".join(
                f"printf '{line}\\n'" for line in resize_lines
            )
            client.send_surface(surface_id, f"{clear_and_draw}\n")
            _wait_for(lambda: resize_lines[-1] in _surface_scrollback_text(client, workspace_id, surface_id), timeout_s=8.0)

            pre_resize_visible = client.read_terminal_text(surface_id)
            pre_visible_lines = [line for line in resize_lines if line in pre_resize_visible]
            _must(
                len(pre_visible_lines) >= 4,
                f"pre-resize viewport did not contain enough lines: {pre_visible_lines}",
            )

            client.new_split("right")
            time.sleep(0.3)

            pane_ids = [pid for _idx, pid, _count, _focused in client.list_panes()]
            pane_id = _pane_for_surface(client, surface_id)
            resize_direction, resize_axis = _pick_resize_direction_for_pane(client, pane_ids, pane_id)
            pre_extent = _pane_extent(client, pane_id, resize_axis)

            resize_result = client._call(
                "pane.resize",
                {
                    "workspace_id": workspace_id,
                    "pane_id": pane_id,
                    "direction": resize_direction,
                    "amount": 80,
                },
            ) or {}
            _must(
                str(resize_result.get("pane_id") or "") == pane_id,
                f"pane.resize response missing expected pane_id: {resize_result}",
            )
            _wait_for(lambda: _pane_extent(client, pane_id, resize_axis) > pre_extent + 1.0, timeout_s=5.0)

            post_resize_visible = client.read_terminal_text(surface_id)
            visible_overlap = [line for line in pre_visible_lines if line in post_resize_visible]
            _must(
                bool(visible_overlap),
                f"resize lost all pre-resize visible lines from viewport: {pre_visible_lines}",
            )

            post_token = f"CMUX_LOCAL_RESIZE_POST_{stamp}"
            client.send_surface(surface_id, f"printf '{post_token}\\n'\n")
            _wait_for(lambda: post_token in client.read_terminal_text(surface_id), timeout_s=8.0)

            scrollback_text = _surface_scrollback_text(client, workspace_id, surface_id)
            _must(
                resize_lines[0] in scrollback_text and resize_lines[-1] in scrollback_text,
                "terminal scrollback lost pre-resize lines after pane resize",
            )
            _must(
                post_token in scrollback_text,
                "terminal scrollback missing post-resize token after pane resize",
            )

            client.close_workspace(workspace_id)
            workspace_id = ""

        print("PASS: pane.resize preserves pre-resize visible content and scrollback anchors")
        return 0
    finally:
        if workspace_id:
            try:
                with cmux(socket_path) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass


def main() -> int:
    env_socket = os.environ.get("CMUX_SOCKET")
    if env_socket:
        return _run_once(env_socket)

    last_error: Exception | None = None
    for socket_path in DEFAULT_SOCKET_PATHS:
        try:
            return _run_once(socket_path)
        except cmuxError as exc:
            text = str(exc)
            recoverable = (
                "Failed to connect",
                "Socket not found",
            )
            if not any(token in text for token in recoverable):
                raise
            last_error = exc
            continue

    if last_error is not None:
        raise last_error
    raise cmuxError("No socket candidates configured")


if __name__ == "__main__":
    raise SystemExit(main())
