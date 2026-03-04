#!/usr/bin/env python3
"""Regression test: splitting down in a sibling pane must not resize the left terminal.

Repro:
  1) Cmd+D (split right) — creates left and right panes.
  2) Cmd+Shift+D (split down in right pane) — right pane splits vertically.
  3) Ctrl+D (close new bottom-right pane).

Bug: the left pane's size oscillates by ±17pt (overlay scrollbar width) during
sibling split/close operations because two code paths (layout() vs
synchronizeCoreSurface()) were feeding different widths into ghostty's
terminal resize, causing reflow and visible content shifts.

We validate that the left pane frame remains stable (within 1px tolerance)
through both the sibling split and the sibling close.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

# Allow 1px tolerance for rounding differences between layout passes.
FRAME_TOLERANCE = 1.0


def _sorted_panes_by_x(payload: dict) -> list[dict]:
    layout = payload.get("layout") or payload
    panes = layout.get("panes") or []
    return sorted(panes, key=lambda p: float((p.get("frame") or {}).get("x", 0.0)))


def _frame_eq(a: dict, b: dict, tol: float = FRAME_TOLERANCE) -> bool:
    for key in ("x", "y", "width", "height"):
        if abs(float(a.get(key, 0)) - float(b.get(key, 0))) > tol:
            return False
    return True


def _frame_str(f: dict) -> str:
    return f"{f.get('width', '?')}x{f.get('height', '?')} @ ({f.get('x', '?')},{f.get('y', '?')})"


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        ws = c.new_workspace()
        time.sleep(0.3)

        # Step 1: Split right (Cmd+D).
        c.new_split("right")
        time.sleep(0.5)

        layout1 = c.layout_debug()
        panes1 = _sorted_panes_by_x(layout1)
        if len(panes1) < 2:
            raise cmuxError(f"expected >=2 panes after split right, got {len(panes1)}")

        left_pane_id = str(panes1[0].get("paneId"))
        right_pane_id = str(panes1[-1].get("paneId"))
        left_frame_after_split = panes1[0]["frame"]
        print(f"After split right: left={_frame_str(left_frame_after_split)} panes={len(panes1)}")

        # Step 2: Focus right pane, split down (Cmd+Shift+D).
        c.focus_pane(right_pane_id)
        time.sleep(0.2)
        c.new_split("down")
        time.sleep(0.5)

        layout2 = c.layout_debug()
        panes2 = _sorted_panes_by_x(layout2)
        if len(panes2) < 3:
            raise cmuxError(f"expected >=3 panes after split down, got {len(panes2)}")

        left_frame_after_down = panes2[0]["frame"]
        print(f"After split down: left={_frame_str(left_frame_after_down)} panes={len(panes2)}")

        if not _frame_eq(left_frame_after_split, left_frame_after_down):
            raise cmuxError(
                f"Left pane resized after sibling split down! "
                f"before={_frame_str(left_frame_after_split)} "
                f"after={_frame_str(left_frame_after_down)}"
            )

        # Step 3: Close the bottom-right pane (find and close the newest surface).
        surfaces = c.list_surfaces()
        # The focused surface after split down is typically the new one.
        focused = [s for s in surfaces if s[2]]
        if focused:
            c.close_surface(focused[0][1])
        time.sleep(0.5)

        layout3 = c.layout_debug()
        panes3 = _sorted_panes_by_x(layout3)
        left_frame_after_close = panes3[0]["frame"]
        print(f"After close: left={_frame_str(left_frame_after_close)} panes={len(panes3)}")

        if not _frame_eq(left_frame_after_split, left_frame_after_close):
            raise cmuxError(
                f"Left pane resized after sibling close! "
                f"before={_frame_str(left_frame_after_split)} "
                f"after={_frame_str(left_frame_after_close)}"
            )

        # Cleanup.
        c.close_workspace(ws)
        time.sleep(0.1)

    print("PASS: left pane size stable through sibling split and close")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
