#!/usr/bin/env python3
"""
Regression test: file-drop overlay must not intercept bonsplit tab-transfer drags.

This test is socket-only (no System Events / Accessibility permissions required).
It validates both FileDropOverlayView hit-test and drag-destination gate logic:

1) tabtransfer/sidebar-reorder payloads never capture
2) fileURL captures only valid external file-drop paths
3) local drags are never captured by file-drop destination routing
4) mixed payloads (fileURL + tabtransfer/sidebar) are never captured
"""

import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


DRAG_EVENTS = [
    "leftMouseDragged",
    "rightMouseDragged",
    "otherMouseDragged",
]

NON_DRAG_EVENTS = [
    "leftMouseDown",
    "leftMouseUp",
    "rightMouseDown",
    "rightMouseUp",
    "otherMouseDown",
    "otherMouseUp",
    "scrollWheel",
]


def wait_for_overlay_probe_ready(client: cmux, timeout_s: float = 8.0) -> None:
    start = time.time()
    last_error = None
    while time.time() - start < timeout_s:
        try:
            _ = client.overlay_hit_gate("none")
            _ = client.overlay_drop_gate("external")
            _ = client.overlay_drop_gate("local")
            return
        except Exception as e:
            last_error = e
            time.sleep(0.1)
    raise cmuxError(f"overlay_hit_gate probe unavailable: {last_error}")


def assert_gate(client: cmux, event_type: str, expected: bool, reason: str) -> None:
    got = client.overlay_hit_gate(event_type)
    if got != expected:
        raise cmuxError(
            f"overlay_hit_gate({event_type}) expected {expected} got {got} ({reason})"
        )


def assert_drop_gate(client: cmux, source: str, expected: bool, reason: str) -> None:
    got = client.overlay_drop_gate(source)
    if got != expected:
        raise cmuxError(
            f"overlay_drop_gate({source}) expected {expected} got {got} ({reason})"
        )


def main() -> int:
    socket_path = cmux.default_socket_path()
    if not os.path.exists(socket_path):
        print(f"SKIP: Socket not found at {socket_path}")
        print("Tip: start cmux first (or set CMUX_TAG / CMUX_SOCKET_PATH).")
        return 0

    with cmux(socket_path) as client:
        ws_id = None
        try:
            client.activate_app()
            time.sleep(0.2)

            ws_id = client.new_workspace()
            client.select_workspace(ws_id)
            time.sleep(0.4)

            wait_for_overlay_probe_ready(client)

            client.clear_drag_pasteboard()
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="empty drag pasteboard")
            assert_drop_gate(client, "external", expected=False, reason="empty pasteboard")
            assert_drop_gate(client, "local", expected=False, reason="empty pasteboard")

            client.seed_drag_pasteboard_tabtransfer()
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="tabtransfer drag must pass through")
            assert_drop_gate(client, "external", expected=False, reason="tabtransfer drag must pass through")
            assert_drop_gate(client, "local", expected=False, reason="tabtransfer drag must pass through")

            client.seed_drag_pasteboard_sidebar_reorder()
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="sidebar reorder drag must pass through")
            assert_drop_gate(client, "external", expected=False, reason="sidebar reorder drag must pass through")
            assert_drop_gate(client, "local", expected=False, reason="sidebar reorder drag must pass through")

            client.seed_drag_pasteboard_fileurl()
            for event in DRAG_EVENTS:
                assert_gate(client, event, expected=True, reason="file URL drag should be captured")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="non-drag events should pass through")
            assert_drop_gate(client, "external", expected=True, reason="external file drags should be captured")
            assert_drop_gate(client, "local", expected=False, reason="local drags must not be captured")

            client.seed_drag_pasteboard_types(["fileurl", "tabtransfer"])
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="fileurl+tabtransfer must pass through")
            assert_drop_gate(client, "external", expected=False, reason="fileurl+tabtransfer must pass through")
            assert_drop_gate(client, "local", expected=False, reason="fileurl+tabtransfer must pass through")

            client.seed_drag_pasteboard_types(["fileurl", "sidebarreorder"])
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="fileurl+sidebarreorder must pass through")
            assert_drop_gate(client, "external", expected=False, reason="fileurl+sidebarreorder must pass through")
            assert_drop_gate(client, "local", expected=False, reason="fileurl+sidebarreorder must pass through")

            print("PASS: overlay hit/drop gates preserve bonsplit drags and external file-drop behavior")
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
    except cmuxError as e:
        print(f"FAIL: {e}")
        raise SystemExit(1)
