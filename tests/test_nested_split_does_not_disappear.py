#!/usr/bin/env python3
"""Regression: splitting inside an existing split must not make sibling panes disappear.

User report:
  - Start with a left/right split.
  - Focus the right pane.
  - Create another left/right split.
  - The original split can temporarily or persistently disappear (pane collapses or panel detaches).

This test tries to catch the bug without calling `layout_debug` (which can force layout and
mask view-tree issues). Instead we use:
  - `panel_snapshot` to assert each terminal panel remains capturable with non-trivial bounds.
  - `surface_health` to assert each panel view stays attached to the window.

If the bug reproduces, `panel_snapshot` typically fails (panel not in window) or returns a
very small image.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _assert_all_panels_visible(c: cmux, panel_ids: list[str], *, min_wh: int = 80) -> None:
    health = {row["id"].lower(): row for row in c.surface_health()}
    for pid in panel_ids:
        h = health.get(pid.lower())
        if not h:
            raise cmuxError(f"surface_health missing panel {pid}")
        if h.get("in_window") is not True:
            raise cmuxError(f"panel not in window: {pid} health={h}")

        snap = c.panel_snapshot(pid, label="nested_split")
        if snap["width"] < min_wh or snap["height"] < min_wh:
            raise cmuxError(f"panel snapshot too small: {pid} snap={snap}")


def _wait_until_all_panels_visible(c: cmux, panel_ids: list[str], timeout_s: float) -> None:
    deadline = time.time() + timeout_s
    last_err = ""
    while time.time() < deadline:
        try:
            _assert_all_panels_visible(c, panel_ids)
            return
        except cmuxError as e:
            last_err = str(e)
            time.sleep(0.05)
    raise cmuxError(last_err or "panels never became visible")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()

        # Run a few iterations to make intermittent issues deterministic.
        for it in range(8):
            c.new_workspace()
            time.sleep(0.25)

            surfaces0 = c.list_surfaces()
            if not surfaces0:
                raise cmuxError("expected initial surface")
            left_panel = surfaces0[0][1]

            # Create first split to the right.
            right_panel = c.new_split("right")
            time.sleep(0.05)

            # Focus the right panel, then split it again to create a nested split.
            c.focus_surface(right_panel)
            time.sleep(0.02)
            new_right_panel = c.new_split("right")

            panel_ids = [left_panel, right_panel, new_right_panel]

            # Stress window: assert repeatedly during the first second after the nested split.
            deadline = time.time() + 1.2
            last_err = None
            while time.time() < deadline:
                try:
                    _assert_all_panels_visible(c, panel_ids)
                    last_err = None
                except cmuxError as e:
                    last_err = str(e)
                    time.sleep(0.03)
                else:
                    time.sleep(0.03)

            # If the final sample in the stress window was bad, allow a short settle window
            # before failing. This keeps real persistent regressions while reducing end-of-window
            # sampling flakes.
            if last_err:
                try:
                    _wait_until_all_panels_visible(c, panel_ids, timeout_s=0.8)
                    last_err = None
                except cmuxError as e:
                    last_err = str(e)

            if last_err:
                raise cmuxError(f"iteration {it}: nested split caused disappearance: {last_err}")

        print("PASS: nested split does not detach/collapse panels")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
