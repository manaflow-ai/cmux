#!/usr/bin/env python3
"""Test: workspace.create with layout parameter creates split panes and surfaces."""

from __future__ import annotations

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


def _pane_count(c: cmux, workspace_id: str) -> int:
    payload = c._call("pane.list", {"workspace_id": workspace_id}) or {}
    return len(payload.get("panes") or [])


def _surface_list(c: cmux, workspace_id: str) -> list:
    payload = c._call("surface.list", {"workspace_id": workspace_id}) or {}
    return list(payload.get("surfaces") or [])


def _close_workspace_quietly(c: cmux, workspace_id: str) -> None:
    try:
        c.close_workspace(workspace_id)
    except cmuxError as err:
        print(f"  WARN: failed to close workspace {workspace_id}: {err}", file=sys.stderr)


def _create_and_get_id(c: cmux, params: dict) -> str:
    payload = c._call("workspace.create", params) or {}
    ws_id = str(payload.get("workspace_id") or "")
    _must(bool(ws_id), f"workspace.create returned no workspace_id: {payload}")
    return ws_id


def test_horizontal_split(c: cmux) -> None:
    """Two terminal panes side by side."""
    baseline = c.current_workspace()
    ws = ""
    try:
        ws = _create_and_get_id(c, {
            "title": "test_hsplit",
            "layout": {
                "direction": "horizontal",
                "split": 0.5,
                "children": [
                    {"pane": {"surfaces": [{"type": "terminal", "name": "Left"}]}},
                    {"pane": {"surfaces": [{"type": "terminal", "name": "Right"}]}},
                ],
            },
        })
        _must(c.current_workspace() == baseline, "should not steal focus")
        c.select_workspace(ws)
        _must(_pane_count(c, ws) == 2, f"expected 2 panes, got {_pane_count(c, ws)}")
        surfaces = _surface_list(c, ws)
        _must(len(surfaces) == 2, f"expected 2 surfaces, got {len(surfaces)}")
        types = {str(s.get("type")) for s in surfaces}
        _must(types == {"terminal"}, f"expected all terminal surfaces, got {types}")
        c.select_workspace(baseline)
    finally:
        if ws:
            _close_workspace_quietly(c, ws)
    print("  PASS: horizontal split creates 2 terminal panes")


def test_nested_splits(c: cmux) -> None:
    """Three panes: left terminal, top-right terminal, bottom-right terminal."""
    baseline = c.current_workspace()
    ws = ""
    try:
        ws = _create_and_get_id(c, {
            "title": "test_nested",
            "layout": {
                "direction": "horizontal",
                "split": 0.5,
                "children": [
                    {"pane": {"surfaces": [{"type": "terminal"}]}},
                    {
                        "direction": "vertical",
                        "split": 0.5,
                        "children": [
                            {"pane": {"surfaces": [{"type": "terminal"}]}},
                            {"pane": {"surfaces": [{"type": "terminal"}]}},
                        ],
                    },
                ],
            },
        })
        c.select_workspace(ws)
        _must(_pane_count(c, ws) == 3, f"expected 3 panes, got {_pane_count(c, ws)}")
        c.select_workspace(baseline)
    finally:
        if ws:
            _close_workspace_quietly(c, ws)
    print("  PASS: nested splits create 3 panes")


def test_env_vars(c: cmux) -> None:
    """Per-surface env vars are applied to terminal surfaces."""
    baseline = c.current_workspace()
    ws = ""
    try:
        token = f"tok_{int(time.time() * 1000)}"
        ws = _create_and_get_id(c, {
            "title": "test_env",
            "layout": {
                "pane": {
                    "surfaces": [{
                        "type": "terminal",
                        "env": {"CMUX_LAYOUT_TEST_TOKEN": token},
                    }],
                },
            },
        })
        c.select_workspace(ws)
        surfaces = _surface_list(c, ws)
        _must(len(surfaces) >= 1, f"expected at least 1 surface, got {len(surfaces)}")
        surface_id = str(surfaces[0].get("id"))
        c.send_surface(surface_id, "printf 'CHECK=%s\\n' \"$CMUX_LAYOUT_TEST_TOKEN\"\\n")
        text = _wait_for_text(c, ws, f"CHECK={token}")
        _must(f"CHECK={token}" in text, f"env var not found in output: {text!r}")
        c.select_workspace(baseline)
    finally:
        if ws:
            _close_workspace_quietly(c, ws)
    print("  PASS: per-surface env vars are applied")


def test_surface_commands(c: cmux) -> None:
    """Per-surface commands are executed in terminal surfaces."""
    baseline = c.current_workspace()
    ws = ""
    try:
        token = f"cmd_{int(time.time() * 1000)}"
        ws = _create_and_get_id(c, {
            "title": "test_cmd",
            "layout": {
                "pane": {
                    "surfaces": [{
                        "type": "terminal",
                        "command": f"echo {token}",
                    }],
                },
            },
        })
        c.select_workspace(ws)
        text = _wait_for_text(c, ws, token)
        _must(token in text, f"command output not found: {text!r}")
        c.select_workspace(baseline)
    finally:
        if ws:
            _close_workspace_quietly(c, ws)
    print("  PASS: per-surface commands are executed")


def test_multi_surface_pane(c: cmux) -> None:
    """Multiple surfaces (tabs) in a single pane."""
    baseline = c.current_workspace()
    ws = ""
    try:
        ws = _create_and_get_id(c, {
            "title": "test_multi",
            "layout": {
                "pane": {
                    "surfaces": [
                        {"type": "terminal", "name": "Tab1"},
                        {"type": "terminal", "name": "Tab2"},
                    ],
                },
            },
        })
        c.select_workspace(ws)
        _must(_pane_count(c, ws) == 1, f"expected 1 pane, got {_pane_count(c, ws)}")
        surfaces = _surface_list(c, ws)
        _must(len(surfaces) == 2, f"expected 2 surfaces, got {len(surfaces)}")
        c.select_workspace(baseline)
    finally:
        if ws:
            _close_workspace_quietly(c, ws)
    print("  PASS: multi-surface pane creates tabs within one pane")


def test_malformed_layout_rejected(c: cmux) -> None:
    """Malformed layout returns an error and does not create a workspace."""
    baseline_workspaces = c._call("workspace.list") or {}
    baseline_count = len((baseline_workspaces.get("workspaces") or []))

    # Split with only 1 child — should be rejected
    try:
        c._call("workspace.create", {
            "title": "test_bad",
            "layout": {
                "direction": "horizontal",
                "children": [
                    {"pane": {"surfaces": [{"type": "terminal"}]}},
                ],
            },
        })
        raise cmuxError("Expected error for malformed layout, but call succeeded")
    except cmuxError as e:
        if "invalid_params" in str(e) or "Invalid layout" in str(e):
            pass  # expected
        else:
            raise

    after_workspaces = c._call("workspace.list") or {}
    after_count = len((after_workspaces.get("workspaces") or []))
    _must(after_count == baseline_count, f"malformed layout created a workspace: {baseline_count} -> {after_count}")
    print("  PASS: malformed layout is rejected without creating a workspace")


def test_empty_surfaces_rejected(c: cmux) -> None:
    """Pane with empty surfaces array is rejected."""
    baseline_workspaces = c._call("workspace.list") or {}
    baseline_count = len((baseline_workspaces.get("workspaces") or []))

    try:
        c._call("workspace.create", {
            "title": "test_empty",
            "layout": {
                "pane": {"surfaces": []},
            },
        })
        raise cmuxError("Expected error for empty surfaces, but call succeeded")
    except cmuxError as e:
        if "invalid_params" in str(e) or "Invalid layout" in str(e):
            pass  # expected
        else:
            raise

    after_workspaces = c._call("workspace.list") or {}
    after_count = len((after_workspaces.get("workspaces") or []))
    _must(after_count == baseline_count, f"empty surfaces created a workspace: {baseline_count} -> {after_count}")
    print("  PASS: empty surfaces array is rejected")


def test_layout_overrides_initial_command_and_env(c: cmux) -> None:
    """When layout is provided, initial_command and initial_env are ignored."""
    baseline = c.current_workspace()
    ws = ""
    try:
        token = f"layout_only_{int(time.time() * 1000)}"
        ws = _create_and_get_id(c, {
            "title": "test_precedence",
            "initial_command": "echo SHOULD_NOT_RUN",
            "initial_env": {"SHOULD_NOT_EXIST": "1"},
            "layout": {
                "pane": {
                    "surfaces": [{
                        "type": "terminal",
                        "env": {"CMUX_LAYOUT_TEST_TOKEN": token},
                        "command": f"echo LAYOUT_CMD_{token}",
                    }],
                },
            },
        })
        c.select_workspace(ws)
        text = _wait_for_text(c, ws, f"LAYOUT_CMD_{token}")
        _must(f"LAYOUT_CMD_{token}" in text, f"layout command missing: {text!r}")
        _must("SHOULD_NOT_RUN" not in text, f"initial_command unexpectedly ran: {text!r}")
        # Verify initial_env was ignored and layout env was applied
        surfaces = _surface_list(c, ws)
        _must(len(surfaces) >= 1, f"expected at least 1 surface, got {len(surfaces)}")
        surface_id = str(surfaces[0].get("id"))
        c.send_surface(
            surface_id,
            "printf 'LAYOUT_ENV=%s INITIAL_ENV=%s\\n' \"$CMUX_LAYOUT_TEST_TOKEN\" \"$SHOULD_NOT_EXIST\"\\n",
        )
        env_text = _wait_for_text(c, ws, f"LAYOUT_ENV={token}")
        _must(f"LAYOUT_ENV={token}" in env_text, f"layout env missing: {env_text!r}")
        _must("INITIAL_ENV=1" not in env_text, f"initial_env unexpectedly applied: {env_text!r}")
        c.select_workspace(baseline)
    finally:
        if ws:
            _close_workspace_quietly(c, ws)
    print("  PASS: layout overrides initial_command and initial_env")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        print("test_workspace_create_layout:")
        test_horizontal_split(c)
        test_nested_splits(c)
        test_env_vars(c)
        test_surface_commands(c)
        test_multi_surface_pane(c)
        test_layout_overrides_initial_command_and_env(c)
        test_malformed_layout_rejected(c)
        test_empty_surfaces_rejected(c)

    print("PASS: all workspace.create layout tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
