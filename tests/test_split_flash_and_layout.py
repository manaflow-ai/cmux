#!/usr/bin/env python3
"""
Layout/flash regression tests for cmuxterm splits.

Goals:
  1) Ensure programmatic splits don't transiently render EmptyPanelView (visible flash).
  2) Validate selected panel bounds are non-zero and aligned with bonsplit pane bounds.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _rect_area(r: dict) -> float:
    return max(0.0, float(r.get("width", 0.0))) * max(0.0, float(r.get("height", 0.0)))


def _rect_intersection_area(a: dict, b: dict) -> float:
    ax1 = float(a["x"])
    ay1 = float(a["y"])
    ax2 = ax1 + float(a["width"])
    ay2 = ay1 + float(a["height"])

    bx1 = float(b["x"])
    by1 = float(b["y"])
    bx2 = bx1 + float(b["width"])
    by2 = by1 + float(b["height"])

    ix1 = max(ax1, bx1)
    iy1 = max(ay1, by1)
    ix2 = min(ax2, bx2)
    iy2 = min(ay2, by2)

    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    return (ix2 - ix1) * (iy2 - iy1)


def _assert_selected_panels_healthy(payload: dict, *, min_wh: float = 80.0) -> None:
    selected = payload.get("selectedPanels") or []
    if not selected:
        raise cmuxError("layout_debug returned no selectedPanels")

    for i, row in enumerate(selected):
        pane_id = row.get("paneId")
        pane_frame = row.get("paneFrame")
        view_frame = row.get("viewFrame")

        panel_id = row.get("panelId")
        if not panel_id:
            raise cmuxError(f"selectedPanels[{i}] missing panelId (pane={pane_id})")

        if row.get("inWindow") is not True:
            raise cmuxError(f"selectedPanels[{i}] panel not in window (pane={pane_id}, panel={panel_id})")

        if row.get("hidden") is True:
            raise cmuxError(f"selectedPanels[{i}] panel is hidden (pane={pane_id}, panel={panel_id})")

        if not view_frame:
            raise cmuxError(f"selectedPanels[{i}] missing viewFrame (pane={pane_id}, panel={panel_id})")

        if float(view_frame.get("width", 0.0)) < min_wh or float(view_frame.get("height", 0.0)) < min_wh:
            raise cmuxError(
                f"selectedPanels[{i}] viewFrame too small: {view_frame} (pane={pane_id}, panel={panel_id})"
            )

        # Coordinate sanity: selected panel should substantially overlap its pane.
        # This implicitly verifies we're measuring in a consistent coordinate space.
        if pane_frame:
            inter = _rect_intersection_area(pane_frame, view_frame)
            denom = min(_rect_area(pane_frame), _rect_area(view_frame))
            ratio = inter / denom if denom > 0 else 0.0
            if ratio < 0.50:
                raise cmuxError(
                    f"selectedPanels[{i}] bounds mismatch (overlap={ratio:.2f}). "
                    f"pane={pane_frame} view={view_frame} pane_id={pane_id} panel={panel_id}"
                )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        # Baseline: a fresh counter, no flashes just from connecting.
        c.reset_empty_panel_count()

        base = c.layout_debug()
        _assert_selected_panels_healthy(base)

        # Programmatic split should not show EmptyPanelView even briefly.
        c.reset_empty_panel_count()
        c.new_split("right")
        time.sleep(0.3)
        flashes = c.empty_panel_count()
        if flashes != 0:
            raise cmuxError(f"EmptyPanelView appeared during split (count={flashes})")

        after = c.layout_debug()
        # Expect at least 2 panes after split (exact count can vary if user already has splits).
        panes = after.get("layout", {}).get("panes") or []
        if len(panes) < 2:
            raise cmuxError(f"Expected >= 2 panes after split, got {len(panes)}")
        _assert_selected_panels_healthy(after)

        # Browser split should also avoid EmptyPanelView flashes.
        c.reset_empty_panel_count()
        browser_id = c._send_command("open_browser https://example.com")
        if not browser_id.startswith("OK "):
            raise cmuxError(browser_id)
        time.sleep(0.4)
        flashes = c.empty_panel_count()
        if flashes != 0:
            raise cmuxError(f"EmptyPanelView appeared during browser split (count={flashes})")

        after_browser = c.layout_debug()
        _assert_selected_panels_healthy(after_browser)

    print("PASS: split flash + layout bounds checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

