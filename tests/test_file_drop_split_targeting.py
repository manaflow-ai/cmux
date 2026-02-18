#!/usr/bin/env python3
"""
Regression test: file drops in vertical splits target the correct terminal.

When the window has a vertical split (top/bottom), a file drop over the top
terminal must be routed to the top terminal (not the bottom one), and vice
versa.  A coordinate-system bug (y-axis inversion in hitTest) previously
caused drops to land in the wrong pane.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux


def surface_ids_from_layout(layout: dict):
    """Extract panel IDs keyed by vertical position from layout_debug output.

    Returns (top_surface_id, bottom_surface_id) based on pane frame y-origins.
    Bonsplit's pane frames use a top-left origin (flipped) coordinate system,
    so smaller y = higher on screen = top pane.
    """
    panels = layout.get("selectedPanels", [])
    if len(panels) < 2:
        return None, None

    def y_origin(p):
        frame = p.get("paneFrame")
        if frame is None:
            return 0
        return frame.get("y", 0)

    # Sort ascending by y: smallest y = top pane visually
    sorted_panels = sorted(panels, key=y_origin)
    top_id = sorted_panels[0].get("panelId")
    bottom_id = sorted_panels[1].get("panelId")
    return top_id, bottom_id


def main() -> int:
    with cmux() as client:
        try:
            client.activate_app()
        except Exception:
            pass

        # Start with a single terminal surface.
        surfaces = client.list_surfaces()
        if not surfaces:
            client.new_workspace()
            time.sleep(0.3)
            surfaces = client.list_surfaces()
        if not surfaces:
            print("FAIL: no surfaces available")
            return 1

        # Create a vertical (top/bottom) split.
        client.new_split("down")
        time.sleep(0.5)

        layout = client.layout_debug()
        top_panel_id, bottom_panel_id = surface_ids_from_layout(layout)
        if not top_panel_id or not bottom_panel_id:
            print("FAIL: could not determine top/bottom panel IDs from layout")
            print(f"layout: {layout}")
            return 1

        if top_panel_id == bottom_panel_id:
            print("FAIL: top and bottom panel IDs are the same")
            return 1

        # Test the hit-test mapping directly: given a point in the top/bottom
        # half, does it resolve to *different* terminals in the expected order?
        # drop_hit_test uses content-area coordinates: (0,0)=top-left, (1,1)=bottom-right.

        # Hit-test near the vertical centre of the top pane (y ≈ 0.25).
        top_hit = client.drop_hit_test(0.5, 0.25)
        # Hit-test near the vertical centre of the bottom pane (y ≈ 0.75).
        bottom_hit = client.drop_hit_test(0.5, 0.75)

        if top_hit is None:
            print("FAIL: drop_hit_test returned 'none' for top region")
            return 1
        if bottom_hit is None:
            print("FAIL: drop_hit_test returned 'none' for bottom region")
            return 1
        if top_hit == bottom_hit:
            print("FAIL: top and bottom hit test returned the same surface")
            print(f"  top_hit={top_hit}  bottom_hit={bottom_hit}")
            return 1

        # Verify the mapping is not inverted: the top hit should correspond to
        # the top pane and the bottom hit to the bottom pane.
        # Cross-check via layout_debug pane frames (flipped coords: smaller y = top).
        panels = layout.get("selectedPanels", [])
        panel_to_y = {}
        for p in panels:
            pid = p.get("panelId")
            frame = p.get("paneFrame")
            if pid and frame:
                panel_to_y[pid] = frame.get("y", 0)

        # drop_hit_test returns uppercase UUIDs; panelId may differ in case.
        def normalise(uuid_str):
            return uuid_str.upper() if uuid_str else ""

        top_y = panel_to_y.get(normalise(top_hit), panel_to_y.get(top_hit))
        bottom_y = panel_to_y.get(normalise(bottom_hit), panel_to_y.get(bottom_hit))

        if top_y is None or bottom_y is None:
            print("FAIL: could not find hit-test surface IDs in layout panel map")
            print(f"  top_hit={top_hit}  bottom_hit={bottom_hit}")
            print(f"  panel_to_y={panel_to_y}")
            return 1

        # In flipped coords: top pane has smaller y
        if top_y >= bottom_y:
            print("FAIL: y-axis is inverted — top hit resolved to bottom pane")
            print(f"  top_hit={top_hit} (y={top_y})  bottom_hit={bottom_hit} (y={bottom_y})")
            return 1

        print("PASS: vertical split drop targeting is correct")
        print(f"  top_hit={top_hit}  bottom_hit={bottom_hit}")

        # Also test horizontal split targeting.
        # Close the bottom pane and create a horizontal split instead.
        # First, close all extra surfaces to get back to 1.
        surfaces = client.list_surfaces()
        if len(surfaces) > 1:
            # Focus and close the non-first surface
            for _, sid, is_focused in surfaces[1:]:
                try:
                    client.close_surface(sid)
                except Exception:
                    pass
            time.sleep(0.3)

        client.new_split("right")
        time.sleep(0.5)

        # Hit-test left half and right half
        left_hit = client.drop_hit_test(0.25, 0.5)
        right_hit = client.drop_hit_test(0.75, 0.5)

        if left_hit is None:
            print("FAIL: drop_hit_test returned 'none' for left region")
            return 1
        if right_hit is None:
            print("FAIL: drop_hit_test returned 'none' for right region")
            return 1
        if left_hit == right_hit:
            print("FAIL: left and right hit test returned the same surface")
            print(f"  left_hit={left_hit}  right_hit={right_hit}")
            return 1

        print("PASS: horizontal split drop targeting is correct")
        print(f"  left_hit={left_hit}  right_hit={right_hit}")

        return 0


if __name__ == "__main__":
    raise SystemExit(main())
