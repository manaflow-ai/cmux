#!/usr/bin/env python3
"""Regression: pane.resize preserves terminal content drawn before resize."""

from __future__ import annotations

import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError
from pane_resize_test_support import (
    focused_pane_id as _focused_pane_id,
    pane_extent as _pane_extent,
    pick_resize_direction_for_pane as _pick_resize_direction_for_pane,
    scrollback_has_exact_line as _scrollback_has_exact_line,
    surface_scrollback_lines as _surface_scrollback_lines,
    wait_for as _wait_for,
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
    workspace_panes as _workspace_panes,
    must as _must,
)


DEFAULT_SOCKET_PATHS = ["/tmp/cmux-debug.sock", "/tmp/cmux.sock"]


def _run_once(socket_path: str) -> int:
    workspace_id = ""
    try:
        with cmux(socket_path) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]
            _wait_for_surface_command_roundtrip(client, workspace_id, surface_id)

            stamp = secrets.token_hex(4)
            resize_lines = [f"CMUX_LOCAL_RESIZE_LINE_{stamp}_{index:02d}" for index in range(1, 33)]
            clear_and_draw = (
                "clear; "
                f"for i in $(seq 1 {len(resize_lines)}); do "
                "n=$(printf '%02d' \"$i\"); "
                f"echo CMUX_LOCAL_RESIZE_LINE_{stamp}_$n; "
                "done"
            )
            client.send_surface(surface_id, f"{clear_and_draw}\n")
            _wait_for(lambda: _scrollback_has_exact_line(client, workspace_id, surface_id, resize_lines[-1]), timeout_s=8.0)
            pre_resize_scrollback_lines = _surface_scrollback_lines(client, workspace_id, surface_id)
            pre_resize_anchors = [line for line in (resize_lines[0], resize_lines[-1]) if line in pre_resize_scrollback_lines]
            _must(
                len(pre_resize_anchors) == 2,
                f"pre-resize scrollback missing anchor lines: anchors={pre_resize_anchors}",
            )

            pre_resize_visible = client.read_terminal_text(surface_id)
            pre_visible_lines = [line for line in resize_lines if line in pre_resize_visible]
            _must(
                len(pre_visible_lines) >= 4,
                f"pre-resize viewport did not contain enough lines: {pre_visible_lines}",
            )

            split_payload = client._call(
                "surface.split",
                {"workspace_id": workspace_id, "surface_id": surface_id, "direction": "right"},
            ) or {}
            _must(bool(split_payload.get("surface_id")), f"surface.split returned no surface_id: {split_payload}")
            _wait_for(lambda: len(_workspace_panes(client, workspace_id)) >= 2, timeout_s=4.0)

            client.focus_surface(surface_id)
            time.sleep(0.1)
            panes = _workspace_panes(client, workspace_id)
            pane_ids = [pid for pid, _focused, _surface_count in panes]
            pane_id = _focused_pane_id(client, workspace_id)
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
            client.send_surface(surface_id, f"echo {post_token}\n")
            _wait_for(lambda: _scrollback_has_exact_line(client, workspace_id, surface_id, post_token), timeout_s=8.0)

            scrollback_lines = _surface_scrollback_lines(client, workspace_id, surface_id)
            _must(
                all(anchor in scrollback_lines for anchor in pre_resize_anchors),
                "terminal scrollback lost pre-resize lines after pane resize",
            )
            _must(
                post_token in scrollback_lines,
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
