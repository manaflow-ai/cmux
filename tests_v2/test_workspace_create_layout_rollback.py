#!/usr/bin/env python3
"""Test: workspace.create with a layout that fails partway must not orphan a workspace.

Regression for #2951. The schema validation in `v2WorkspaceCreate` only catches
JSON-decoder errors before the workspace is created. Failures inside
`applyCustomLayout` (split nodes with the wrong number of children, anchor-pane
lookup miss, etc.) currently fall through to empty leaves, leaving the workspace
alive while the socket call still returns ok with the workspace_id.

Both `test_malformed_layout_rejected` and `test_empty_surfaces_rejected` in
`test_workspace_create_layout.py` already cover the JSON-decoder path. This test
covers the post-decode rollback that today does not exist.
"""

from __future__ import annotations

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


def _workspace_count(c: cmux) -> int:
    payload = c._call("workspace.list") or {}
    return len(payload.get("workspaces") or [])


def _close_workspace_quietly(c: cmux, workspace_id: str) -> None:
    try:
        c.close_workspace(workspace_id)
    except cmuxError as err:
        print(f"  WARN: failed to close workspace {workspace_id}: {err}", file=sys.stderr)


def _assert_layout_rollback(c: cmux, label: str, layout: dict) -> None:
    print(f"  -> {label}")
    baseline_count = _workspace_count(c)

    rejected = False
    spurious_id: str | None = None
    try:
        payload = c._call("workspace.create", {
            "title": f"layout_rollback_{label}_{int(time.time() * 1000)}",
            "layout": layout,
        }) or {}
        spurious_id = str(payload.get("workspace_id") or "") or None
    except cmuxError as e:
        # The post-decode failure path should surface as `invalid_layout`. The
        # existing JSON-decoder rejection path uses `invalid_params`; allow
        # either so we are not coupled to the exact code wording, but require
        # that the call did not silently succeed.
        msg = str(e)
        if "invalid_layout" in msg or "invalid_params" in msg or "Invalid layout" in msg:
            rejected = True
        else:
            raise

    if not rejected:
        if spurious_id:
            _close_workspace_quietly(c, spurious_id)
        raise cmuxError(
            f"expected error for {label}, but workspace.create returned ok"
        )

    after_count = _workspace_count(c)
    _must(
        after_count == baseline_count,
        f"layout {label} left an orphan workspace: {baseline_count} -> {after_count}",
    )


def test_split_with_one_child_rolls_back(c: cmux) -> None:
    """A `split` node with only one child must not leave a workspace behind."""
    _assert_layout_rollback(c, "split_one_child", {
        "split": {
            "orientation": "horizontal",
            "children": [
                {"pane": {"surfaces": [{"type": "terminal"}]}},
            ],
        },
    })


def test_split_with_three_children_rolls_back(c: cmux) -> None:
    """A `split` node with three children must not leave a workspace behind."""
    _assert_layout_rollback(c, "split_three_children", {
        "split": {
            "orientation": "horizontal",
            "children": [
                {"pane": {"surfaces": [{"type": "terminal"}]}},
                {"pane": {"surfaces": [{"type": "terminal"}]}},
                {"pane": {"surfaces": [{"type": "terminal"}]}},
            ],
        },
    })


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        print("test_workspace_create_layout_rollback:")
        test_split_with_one_child_rolls_back(c)
        test_split_with_three_children_rolls_back(c)
    print("PASS: workspace.create rejects partially-failing layouts and rolls back")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
