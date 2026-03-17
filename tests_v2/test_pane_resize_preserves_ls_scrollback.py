#!/usr/bin/env python3
"""Regression: `ls` output remains in scrollback after pane.resize."""

from __future__ import annotations

import os
import secrets
import shlex
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError
from pane_resize_test_support import (
    clean_line as _clean_line,
    focused_pane_id as _focused_pane_id,
    pane_extent as _pane_extent,
    pick_resize_direction_for_pane as _pick_resize_direction_for_pane,
    scrollback_has_exact_line as _scrollback_has_exact_line,
    surface_scrollback_text as _surface_scrollback_text,
    wait_for as _wait_for,
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
    workspace_panes as _workspace_panes,
)


DEFAULT_SOCKET_PATHS = ["/tmp/cmux-debug.sock", "/tmp/cmux.sock"]


def _has_exact_marker_lines(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    start_marker: str,
    end_marker: str,
) -> bool:
    text = _surface_scrollback_text(client, workspace_id, surface_id)
    lines = [_clean_line(raw) for raw in text.splitlines()]
    return start_marker in lines and end_marker in lines


def _extract_segment_lines(
    text: str,
    start_marker: str,
    end_marker: str,
    *,
    require_end: bool = True,
) -> list[str]:
    lines = text.splitlines()
    saw_start = False
    saw_end = False
    out: list[str] = []
    for raw in lines:
        line = _clean_line(raw)
        if not saw_start:
            if line == start_marker:
                saw_start = True
            continue
        if line == end_marker:
            saw_end = True
            break
        if line:
            out.append(line)

    if not saw_start:
        raise cmuxError(f"start marker not found in scrollback: {start_marker}")
    if require_end and not saw_end:
        raise cmuxError(f"end marker not found in scrollback: {end_marker}")
    return out


def _run_once(socket_path: str) -> int:
    workspace_id = ""
    fixture_dir = Path(tempfile.mkdtemp(prefix="cmux-ls-resize-regression-"))
    try:
        with cmux(socket_path) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]
            _wait_for_surface_command_roundtrip(client, workspace_id, surface_id)

            expected_names = [f"entry-{index:04d}.txt" for index in range(1, 241)]
            for name in expected_names:
                (fixture_dir / name).write_text(name + "\n", encoding="utf-8")

            start_marker = f"CMUX_LS_SCROLLBACK_START_{secrets.token_hex(4)}"
            end_marker = f"CMUX_LS_SCROLLBACK_END_{secrets.token_hex(4)}"
            fixture_arg = shlex.quote(str(fixture_dir))
            run_ls = (
                f"cd {fixture_arg}; "
                f"echo {start_marker}; "
                f"LC_ALL=C CLICOLOR=0 ls -1; "
                f"echo {end_marker}"
            )
            client.send_surface(surface_id, run_ls + "\n")
            _wait_for(
                lambda: _has_exact_marker_lines(client, workspace_id, surface_id, start_marker, end_marker),
                timeout_s=12.0,
            )

            pre_resize_scrollback = _surface_scrollback_text(client, workspace_id, surface_id)
            pre_lines = _extract_segment_lines(pre_resize_scrollback, start_marker, end_marker)
            expected_set = set(expected_names)
            pre_found = [line for line in pre_lines if line in expected_set]
            _must(
                len(set(pre_found)) == len(expected_set),
                f"pre-resize ls output incomplete: found={len(set(pre_found))} expected={len(expected_set)}",
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
                    "amount": 120,
                },
            ) or {}
            _must(
                str(resize_result.get("pane_id") or "") == pane_id,
                f"pane.resize response missing expected pane_id: {resize_result}",
            )
            _wait_for(lambda: _pane_extent(client, pane_id, resize_axis) > pre_extent + 1.0, timeout_s=6.0)

            post_resize_scrollback = _surface_scrollback_text(client, workspace_id, surface_id)
            # Prompt redraw after resize may repaint over trailing marker rows.
            # The regression condition is loss of ls output entries.
            post_lines = _extract_segment_lines(
                post_resize_scrollback,
                start_marker,
                end_marker,
                require_end=False,
            )
            post_found = [line for line in post_lines if line in expected_set]
            _must(
                len(set(post_found)) == len(expected_set),
                "post-resize ls output lost entries from scrollback",
            )

            client.close_workspace(workspace_id)
            workspace_id = ""

        print("PASS: ls output remains fully present in scrollback after pane.resize")
        return 0
    finally:
        if workspace_id:
            try:
                with cmux(socket_path) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass
        shutil.rmtree(fixture_dir, ignore_errors=True)


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
