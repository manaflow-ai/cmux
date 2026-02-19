#!/usr/bin/env python3
"""
Regression test: stale file-drag overlay state must not swallow real mouse clicks.

This uses real HID mouse events (CoreGraphics CGEvent), not XCUI element actions.
It seeds the drag pasteboard with `public.file-url` to force the FileDropOverlayView
stale-drag path, then verifies:

1) A left click changes terminal focus to the clicked pane.
2) A real right click does not break terminal focus routing.
"""

import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def run_osascript(script: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=8,
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            result.args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def is_accessibility_error(err: subprocess.CalledProcessError) -> bool:
    text = f"{getattr(err, 'stderr', '') or ''}\n{getattr(err, 'output', '') or ''}".lower()
    needles = [
        "not allowed to send keystrokes",
        "not allowed assistive access",
        "not allowed to control computer",
        "(1002)",
    ]
    return any(n in text for n in needles)


def app_name_for_bundle(bundle_id: str) -> str:
    out = run_osascript(f'tell application id "{bundle_id}" to get name').stdout.strip()
    if not out:
        raise RuntimeError(f"Could not resolve app name for bundle ID {bundle_id}")
    return out


def front_window_frame(app_name: str) -> tuple[float, float, float, float]:
    script = f'''
tell application "System Events"
    tell process "{app_name}"
        tell front window
            set p to position
            set s to size
            return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
        end tell
    end tell
end tell
'''
    raw = run_osascript(script).stdout.strip()
    parts = [p.strip() for p in raw.split(",")]
    if len(parts) != 4:
        raise RuntimeError(f"Unexpected window frame from osascript: {raw}")
    x, y, w, h = (float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
    return x, y, w, h


def post_click_with_cgevent(x: float, y: float, right: bool = False) -> None:
    ix = int(round(x))
    iy = int(round(y))
    if right:
        down = ".rightMouseDown"
        up = ".rightMouseUp"
        button = ".right"
    else:
        down = ".leftMouseDown"
        up = ".leftMouseUp"
        button = ".left"

    code = f"""
import CoreGraphics
let p = CGPoint(x: {ix}, y: {iy})
let source = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(mouseEventSource: source, mouseType: {down}, mouseCursorPosition: p, mouseButton: {button})
let up = CGEvent(mouseEventSource: source, mouseType: {up}, mouseCursorPosition: p, mouseButton: {button})
down?.post(tap: .cghidEventTap)
up?.post(tap: .cghidEventTap)
"""
    subprocess.run(
        ["swift", "-e", code],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )


def pick_top_bottom_terminal_panels(layout: dict) -> tuple[dict, dict]:
    candidates = []
    for panel in layout.get("selectedPanels", []):
        if panel.get("panelType") != "terminal":
            continue
        view = panel.get("viewFrame")
        if not isinstance(view, dict):
            continue
        if not panel.get("panelId"):
            continue
        candidates.append(panel)

    if len(candidates) < 2:
        raise RuntimeError(f"Expected >=2 terminal panels with viewFrame, got: {candidates}")

    candidates.sort(key=lambda p: float(p["viewFrame"]["y"]))
    bottom = candidates[0]
    top = candidates[-1]
    if bottom["panelId"] == top["panelId"]:
        raise RuntimeError("Top/bottom panel IDs collapsed to the same panel")
    return top, bottom


def candidate_screen_points(
    window_x: float, window_y: float, window_h: float, panel: dict
) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []

    pane = panel.get("paneFrame") or {}
    view = panel.get("viewFrame") or {}

    window_points: list[tuple[float, float]] = []
    if pane:
        px = float(pane["x"])
        py = float(pane["y"])
        pw = float(pane["width"])
        ph = float(pane["height"])
        window_points.extend([
            (px + pw * 0.50, py + ph * 0.50),
            (px + pw * 0.50, py + min(24.0, ph * 0.20)),
            (px + pw * 0.50, py + max(ph - 24.0, ph * 0.80)),
        ])

    if view:
        vx = float(view["x"])
        vy = float(view["y"])
        vw = float(view["width"])
        vh = float(view["height"])
        window_points.extend([
            (vx + vw * 0.50, vy + vh * 0.50),
            (vx + vw * 0.50, vy + min(24.0, vh * 0.20)),
            (vx + vw * 0.50, vy + max(vh - 24.0, vh * 0.80)),
        ])

    # Try both y-axis interpretations; multi-display setups and coordinate-space
    # conversions can differ by API surface.
    for wx, wy in window_points:
        points.append((window_x + wx, window_y + wy))
        points.append((window_x + wx, window_y + (window_h - wy)))

    # Deduplicate while preserving order.
    dedup: list[tuple[float, float]] = []
    seen: set[tuple[int, int]] = set()
    for sx, sy in points:
        key = (int(round(sx)), int(round(sy)))
        if key in seen:
            continue
        seen.add(key)
        dedup.append((sx, sy))
    return dedup


def wait_for_terminal_focus(client: cmux, panel_id: str, timeout_s: float = 2.0) -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        try:
            if client.is_terminal_focused(panel_id):
                return True
        except Exception:
            pass
        time.sleep(0.05)
    return False


def attempt_focus_via_real_clicks(
    client: cmux,
    panel_id: str,
    points: list[tuple[float, float]],
) -> tuple[bool, tuple[float, float]]:
    last_point = points[0]
    for tx, ty in points:
        last_point = (tx, ty)
        for _ in range(2):
            post_click_with_cgevent(tx, ty, right=False)
            if wait_for_terminal_focus(client, panel_id, timeout_s=0.35):
                return True, (tx, ty)
    return False, last_point


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

            client.seed_drag_pasteboard_fileurl()
            client.activate_app()
            time.sleep(0.2)

            focused, point = attempt_focus_via_real_clicks(client, bottom_id, candidate_points)
            click_x, click_y = point
            if not focused:
                print("FAIL: real left click did not focus clicked pane under stale drag pasteboard")
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

            print("PASS: stale file-drag overlay forwards real left/right clicks")
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
