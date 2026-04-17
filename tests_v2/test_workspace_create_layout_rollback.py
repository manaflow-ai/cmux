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


def _workspace_ids(c: cmux) -> set[str]:
    payload = c._call("workspace.list") or {}
    return {
        str(w.get("id"))
        for w in (payload.get("workspaces") or [])
        if w.get("id")
    }


def _close_workspace_quietly(c: cmux, workspace_id: str) -> None:
    try:
        c.close_workspace(workspace_id)
    except cmuxError as err:
        print(f"  WARN: failed to close workspace {workspace_id}: {err}", file=sys.stderr)


def _assert_layout_rollback(c: cmux, label: str, layout: dict) -> None:
    print(f"  -> {label}")
    # Capture the baseline as a set of IDs instead of a count so unrelated
    # concurrent create/close activity (e.g. from other socket clients in
    # the same CI run) cannot produce a false "orphan" signal as long as
    # the IDs it touches are distinct from ours.
    baseline_ids = _workspace_ids(c)

    rejected = False
    spurious_id: str | None = None
    try:
        payload = c._call("workspace.create", {
            "title": f"layout_rollback_{label}_{int(time.time() * 1000)}",
            "layout": layout,
        }) or {}
        spurious_id = str(payload.get("workspace_id") or "") or None
    except cmuxError as e:
        # We deliberately require `invalid_layout` (and not the JSON-decoder's
        # `invalid_params`) so this test fails if the payload starts being
        # rejected at decode time instead of exercising the post-decode
        # rollback path that #2951 introduces.
        msg = str(e)
        if "invalid_layout" in msg:
            rejected = True
        else:
            raise

    if not rejected:
        if spurious_id:
            _close_workspace_quietly(c, spurious_id)
        raise cmuxError(
            f"expected invalid_layout error for {label}, but workspace.create returned ok"
        )

    after_ids = _workspace_ids(c)
    new_ids = after_ids - baseline_ids
    _must(
        not new_ids,
        f"layout {label} left orphan workspace(s): {sorted(new_ids)}",
    )


def test_split_with_one_child_rolls_back(c: cmux) -> None:
    """A split node with only one child must not leave a workspace behind.

    The payload uses the `direction`/`children` schema that `CmuxLayoutNode`
    accepts (see `test_workspace_create_layout.py`), so it decodes successfully
    and the rejection happens inside `applyCustomLayoutChecked`.
    """
    _assert_layout_rollback(c, "split_one_child", {
        "direction": "horizontal",
        "children": [
            {"pane": {"surfaces": [{"type": "terminal"}]}},
        ],
    })


def test_split_with_three_children_rolls_back(c: cmux) -> None:
    """A split node with three children must not leave a workspace behind."""
    _assert_layout_rollback(c, "split_three_children", {
        "direction": "horizontal",
        "children": [
            {"pane": {"surfaces": [{"type": "terminal"}]}},
            {"pane": {"surfaces": [{"type": "terminal"}]}},
            {"pane": {"surfaces": [{"type": "terminal"}]}},
        ],
    })


def test_valid_two_child_split_still_succeeds(c: cmux) -> None:
    """A well-formed 2-child split must still create a workspace.

    This is the positive-path companion to the rollback tests: if
    `applyCustomLayoutChecked` over-reports failures (e.g. a future refactor
    of the short-circuit in `buildCustomLayoutTree` incorrectly returns
    failures for valid layouts), this test catches it by asserting the
    happy path still produces a workspace and that the transactional
    short-circuit does not regress the legitimate create flow.
    """
    print("  -> valid_two_child_split")
    baseline_ids = _workspace_ids(c)

    payload = c._call("workspace.create", {
        "title": f"layout_positive_{int(time.time() * 1000)}",
        "layout": {
            "direction": "horizontal",
            "children": [
                {"pane": {"surfaces": [{"type": "terminal"}]}},
                {"pane": {"surfaces": [{"type": "terminal"}]}},
            ],
        },
    }) or {}

    new_id = str(payload.get("workspace_id") or "") or None
    _must(
        new_id is not None,
        "valid 2-child split should return a workspace_id",
    )
    assert new_id is not None  # for type narrowing

    after_ids = _workspace_ids(c)
    _must(
        new_id in after_ids,
        f"workspace {new_id} missing from workspace.list after successful create",
    )
    _must(
        after_ids - baseline_ids == {new_id},
        f"unexpected extra workspaces after valid create: "
        f"{sorted(after_ids - baseline_ids - {new_id})}",
    )

    _close_workspace_quietly(c, new_id)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        print("test_workspace_create_layout_rollback:")
        test_split_with_one_child_rolls_back(c)
        test_split_with_three_children_rolls_back(c)
        test_valid_two_child_split_still_succeeds(c)
    print("PASS: workspace.create rejects partially-failing layouts and rolls back")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
