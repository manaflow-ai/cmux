#!/usr/bin/env python3
"""
Regression test: stale tab-transfer drag pasteboard state must not swallow real mouse clicks.

This uses real HID mouse events (CoreGraphics CGEvent), not XCUI element actions.
It seeds the drag pasteboard with `com.splittabbar.tabtransfer` to emulate stale
tab-drag state, then verifies:

1) A left click changes terminal focus to the clicked pane.
2) A real right click does not break terminal focus routing.
"""

import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError
from test_real_click_overlay_forwarding import (
    app_name_for_bundle,
    attempt_focus_via_real_clicks,
    candidate_screen_points,
    front_window_frame,
    is_accessibility_error,
    pick_top_bottom_terminal_panels,
    post_click_with_cgevent,
)


def main() -> int:
    socket_path = cmux.default_socket_path()
    if not os.path.exists(socket_path):
        print(f"SKIP: Socket not found at {socket_path}")
        print("Tip: start cmux first (or set CMUX_TAG / CMUX_SOCKET_PATH).")
        return 0

    bundle_id = cmux.default_bundle_id()
    try:
        app_name = app_name_for_bundle(bundle_id)
    except subprocess.CalledProcessError as e:
        print(f"SKIP: Could not resolve app name for bundle {bundle_id}: {e}")
        return 0

    with cmux(socket_path) as client:
        ws_id = None
        try:
            client.activate_app()
            time.sleep(0.2)

            ws_id = client.new_workspace()
            client.select_workspace(ws_id)
            time.sleep(0.3)

            client.new_split("down")
            time.sleep(0.5)

            layout = client.layout_debug()
            top_panel, bottom_panel = pick_top_bottom_terminal_panels(layout)
            top_id = top_panel["panelId"]
            bottom_id = bottom_panel["panelId"]

            client.focus_surface_by_panel(top_id)
            time.sleep(0.2)

            if client.is_terminal_focused(bottom_id):
                print("FAIL: bottom pane unexpectedly focused before click precondition")
                return 1

            win_x, win_y, _win_w, win_h = front_window_frame(app_name)
            candidate_points = candidate_screen_points(win_x, win_y, win_h, bottom_panel)

            # Baseline: real HID click routing must work before we can assert stale-pasteboard regression.
            client.activate_app()
            time.sleep(0.2)
            baseline_ok, baseline_point = attempt_focus_via_real_clicks(client, bottom_id, candidate_points)
            if not baseline_ok:
                print("SKIP: real HID clicks are not routable on this host right now")
                return 0

            client.focus_surface_by_panel(top_id)
            time.sleep(0.2)
            if client.is_terminal_focused(bottom_id):
                print("FAIL: could not restore top-pane precondition before stale-pasteboard check")
                return 1

            client.seed_drag_pasteboard_tabtransfer()
            client.activate_app()
            time.sleep(0.2)

            focused, point = attempt_focus_via_real_clicks(client, bottom_id, candidate_points)
            click_x, click_y = point
            if not focused:
                print("FAIL: real left click did not focus clicked pane under stale tabtransfer pasteboard")
                print(
                    "baseline_point="
                    f"({baseline_point[0]:.1f}, {baseline_point[1]:.1f}) "
                    f"click_screen=({click_x:.1f}, {click_y:.1f})"
                )
                print(f"top_id={top_id} bottom_id={bottom_id}")
                print(f"layout={layout}")
                return 1

            post_click_with_cgevent(click_x, click_y, right=True)
            time.sleep(0.25)
            if not client.is_terminal_focused(bottom_id):
                print("FAIL: real right click disrupted terminal focus routing")
                return 1

            print("PASS: stale tabtransfer pasteboard preserves real left/right click routing")
            print(f"  focused_panel={bottom_id}")
            return 0
        finally:
            try:
                client.clear_drag_pasteboard()
            except Exception:
                pass
            if ws_id:
                try:
                    client.close_workspace(ws_id)
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as e:
        if is_accessibility_error(e):
            print("SKIP: System Events click automation not allowed (Accessibility permission missing)")
            raise SystemExit(0)
        print(f"FAIL: osascript invocation failed: {e}")
        if getattr(e, "stderr", None):
            print(e.stderr.strip())
        if getattr(e, "output", None):
            print(e.output.strip())
        raise SystemExit(1)
    except cmuxError as e:
        print(f"FAIL: {e}")
        raise SystemExit(1)
