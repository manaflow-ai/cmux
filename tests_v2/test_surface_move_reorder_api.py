#!/usr/bin/env python3
"""v2 regression: surface/workspace move+reorder APIs and ID stability."""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _pane_surface_ids(c: cmux, pane_id: str) -> list[str]:
    rows = c.list_pane_surfaces(pane_id)
    return [sid for _idx, sid, _title, _selected in rows]


def _find_pane_for_surface(c: cmux, surface_id: str) -> str:
    for _pidx, pane_id, _count, _focused in c.list_panes():
        ids = _pane_surface_ids(c, pane_id)
        if surface_id in ids:
            return pane_id
    raise cmuxError(f"Surface not found in any pane: {surface_id}")


def _wait(predicate, timeout: float = 6.0, interval: float = 0.05) -> bool:
    """Poll predicate() until it returns truthy or the timeout elapses.

    Layout mutations (new_split, new_surface, move_surface, reorder_surface,
    new_workspace, reorder_workspace) propagate to the queryable pane/surface/
    workspace lists asynchronously. Poll the real signal instead of sleeping a
    fixed amount and reading once, so the test does not flake when propagation
    is slower than a fixed delay under CI load.
    """
    start = time.time()
    while time.time() - start < timeout:
        if predicate():
            return True
        time.sleep(interval)
    return False


def _wait_pane_for_surface(c: cmux, surface_id: str, timeout: float = 6.0) -> str:
    """Wait until surface_id appears in some pane, then return that pane id."""
    result: dict[str, str] = {}

    def _check() -> bool:
        for _pidx, pane_id, _count, _focused in c.list_panes():
            if surface_id in _pane_surface_ids(c, pane_id):
                result["pane"] = pane_id
                return True
        return False

    if not _wait(_check, timeout=timeout):
        raise cmuxError(f"Surface not found in any pane: {surface_id}")
    return result["pane"]


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        ws0 = c.current_workspace()

        # Ensure at least two panes exist.
        s_right = c.new_split("right")

        # Create one more surface we can move/reorder.
        s_move = c.new_surface(panel_type="terminal")

        # Wait until the new surface is queryable in some pane (and >=2 panes exist).
        src_pane = _wait_pane_for_surface(c, s_move)
        if not _wait(lambda: len({pid for _idx, pid, _count, _focused in c.list_panes()}) >= 2):
            panes_now = [pid for _idx, pid, _count, _focused in c.list_panes()]
            raise cmuxError(f"Expected >=2 panes, got {len(panes_now)}")
        panes = [pid for _idx, pid, _count, _focused in c.list_panes()]
        dst_pane = next((pid for pid in panes if pid != src_pane), None)
        if not dst_pane:
            raise cmuxError("Failed to find destination pane")

        before_src = _pane_surface_ids(c, src_pane)
        before_dst = _pane_surface_ids(c, dst_pane)

        c.move_surface(s_move, pane=dst_pane, focus=False)

        # Poll until the move has propagated: s_move left src and entered dst.
        moved = _wait(
            lambda: s_move not in _pane_surface_ids(c, src_pane)
            and s_move in _pane_surface_ids(c, dst_pane)
        )
        after_src = _pane_surface_ids(c, src_pane)
        after_dst = _pane_surface_ids(c, dst_pane)
        if not moved:
            if s_move in after_src:
                raise cmuxError(f"Expected moved surface to leave source pane (src={src_pane}, ids={after_src})")
            if s_move not in after_dst:
                raise cmuxError(f"Expected moved surface in destination pane (dst={dst_pane}, ids={after_dst})")

        # Reorder inside destination pane; surface ID must remain stable.
        if len(after_dst) < 2:
            extra = c.new_surface(pane=dst_pane, panel_type="terminal")
            if not _wait(lambda: extra in _pane_surface_ids(c, dst_pane)):
                raise cmuxError("Failed to create extra destination surface for reorder test")
            after_dst = _pane_surface_ids(c, dst_pane)

        anchor = after_dst[0]
        c.reorder_surface(s_move, before_surface=anchor)

        # Poll until the reorder has propagated: s_move is at the front of dst.
        _wait(
            lambda: _pane_surface_ids(c, dst_pane)[:1] == [s_move]
        )
        reordered = _pane_surface_ids(c, dst_pane)
        if s_move not in reordered:
            raise cmuxError(f"Expected moved surface to remain in destination pane after reorder (ids={reordered})")
        if reordered[0] != s_move:
            raise cmuxError(f"Expected moved surface at front after reorder (ids={reordered})")
        if sorted(reordered) != sorted(after_dst):
            raise cmuxError(
                f"Expected same set of surface IDs after reorder (before={after_dst}, after={reordered})"
            )

        # Workspace reorder within the current window.
        ws1 = c.new_workspace()
        ws2 = c.new_workspace()

        # Wait until both new workspaces are queryable before reordering.
        _wait(
            lambda: {ws1, ws2}.issubset(
                {wid for _idx, wid, _title, _selected in c.list_workspaces()}
            )
        )

        c.reorder_workspace(ws2, before_workspace=ws0)

        # Poll until the workspace reorder has propagated: ws2 is first.
        _wait(
            lambda: [wid for _idx, wid, _title, _selected in c.list_workspaces()][:1] == [ws2]
        )
        ordered_ws = [wid for _idx, wid, _title, _selected in c.list_workspaces()]
        if not ordered_ws:
            raise cmuxError("workspace.list returned empty after reorder")
        if ordered_ws[0] != ws2:
            raise cmuxError(f"Expected ws2 first after reorder (ordered={ordered_ws}, ws2={ws2})")

        # Keep original workspace selected for better isolation across per-file runs.
        c.select_workspace(ws0)
        _wait(
            lambda: any(
                wid == ws0 and selected
                for _idx, wid, _title, selected in c.list_workspaces()
            ),
            timeout=2.0,
        )

    print("PASS: surface.move/surface.reorder/workspace.reorder keep stable IDs and expected ordering")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
