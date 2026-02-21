#!/usr/bin/env python3
"""
Regression test: file-drop overlay must not intercept bonsplit tab-transfer drags.

This test is socket-only (no System Events / Accessibility permissions required).
It validates the FileDropOverlayView hit-test gate logic:

1) tabtransfer pasteboard type never captures hit-testing
2) sidebar reorder pasteboard type never captures hit-testing
3) fileURL pasteboard captures only drag-motion mouse events
4) stale/no-event contexts do not capture hit-testing
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

            client.seed_drag_pasteboard_tabtransfer()
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="tabtransfer drag must pass through")

            client.seed_drag_pasteboard_sidebar_reorder()
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="sidebar reorder drag must pass through")

            client.seed_drag_pasteboard_fileurl()
            for event in DRAG_EVENTS:
                assert_gate(client, event, expected=True, reason="file URL drag should be captured")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="non-drag events should pass through")

            print("PASS: overlay hit-test gate preserves bonsplit tab drags and file-drop behavior")
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
