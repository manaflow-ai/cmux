#!/usr/bin/env python3
"""
Regression test: drag-routing policy must keep drag/drop features isolated.

This test is socket-only (no System Events / Accessibility permissions required).
It validates:

1) FileDropOverlayView hit-test and drag-destination gates
2) Terminal portal pass-through policy for Bonsplit/sidebar drags
3) Sidebar outside-drop overlay gate
4) Mixed payload behavior (fileURL + tabtransfer/sidebar)
5) Hit-test routing reaches pane-local Bonsplit drop targets (not a root overlay)
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

PORTAL_PASS_THROUGH_EVENTS = DRAG_EVENTS + [
    # Keep portal pass-through strictly scoped to active drag-motion events.
]

NON_DRAG_EVENTS = [
    "mouseMoved",
    "mouseEntered",
    "mouseExited",
    "flagsChanged",
    "cursorUpdate",
    "appKitDefined",
    "systemDefined",
    "applicationDefined",
    "periodic",
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


def assert_portal_gate(client: cmux, event_type: str, expected: bool, reason: str) -> None:
    got = client.portal_hit_gate(event_type)
    if got != expected:
        raise cmuxError(
            f"portal_hit_gate({event_type}) expected {expected} got {got} ({reason})"
        )


def assert_sidebar_gate(client: cmux, state: str, expected: bool, reason: str) -> None:
    got = client.sidebar_overlay_gate(state)
    if got != expected:
        raise cmuxError(
            f"sidebar_overlay_gate({state}) expected {expected} got {got} ({reason})"
        )


def assert_hit_chain_routes_to_pane(
    client: cmux,
    x: float = 0.75,
    y: float = 0.50,
    reason: str = "",
) -> None:
    chain = client.drag_hit_chain(x, y)
    if chain == "none":
        raise cmuxError(
            f"drag_hit_chain({x},{y}) returned none ({reason})"
        )
    # This probe is intended to catch root-level overlay capture regressions.
    # Depending on current AppKit event context, drag hit-testing can resolve
    # through either pane-local SwiftUI wrappers or portal-hosted terminal views.
    if "FileDropOverlayView" in chain:
        raise cmuxError(
            f"drag_hit_chain({x},{y}) unexpectedly captured by FileDropOverlayView ({reason}); chain={chain}"
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
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_portal_gate(client, event, expected=False, reason="empty drag pasteboard")
            assert_sidebar_gate(client, "active", expected=False, reason="empty pasteboard")
            assert_sidebar_gate(client, "inactive", expected=False, reason="empty pasteboard")

            client.seed_drag_pasteboard_tabtransfer()
            assert_hit_chain_routes_to_pane(
                client,
                reason="tabtransfer drag must route into pane-local Bonsplit drop host",
            )
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="tabtransfer drag must pass through")
            assert_drop_gate(client, "external", expected=False, reason="tabtransfer drag must pass through")
            assert_drop_gate(client, "local", expected=False, reason="tabtransfer drag must pass through")
            for event in PORTAL_PASS_THROUGH_EVENTS:
                assert_portal_gate(client, event, expected=True, reason="tabtransfer should pass through terminal portal")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_portal_gate(client, event, expected=False, reason="stale tabtransfer payload must not hijack non-drag portal events")
            assert_sidebar_gate(client, "active", expected=False, reason="tabtransfer is not a sidebar drag payload")
            assert_sidebar_gate(client, "inactive", expected=False, reason="inactive sidebar drag state")

            client.seed_drag_pasteboard_sidebar_reorder()
            assert_hit_chain_routes_to_pane(
                client,
                reason="inactive sidebar reorder payload must not route to root outside-drop overlay",
            )
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="sidebar reorder drag must pass through")
            assert_drop_gate(client, "external", expected=False, reason="sidebar reorder drag must pass through")
            assert_drop_gate(client, "local", expected=False, reason="sidebar reorder drag must pass through")
            for event in PORTAL_PASS_THROUGH_EVENTS:
                assert_portal_gate(client, event, expected=True, reason="sidebar reorder should pass through terminal portal")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_portal_gate(client, event, expected=False, reason="stale sidebar payload must not hijack non-drag portal events")
            assert_sidebar_gate(client, "active", expected=True, reason="active sidebar drag should capture outside overlay")
            assert_sidebar_gate(client, "inactive", expected=False, reason="inactive sidebar drag state")

            client.seed_drag_pasteboard_fileurl()
            for event in DRAG_EVENTS:
                assert_gate(client, event, expected=True, reason="file URL drag should be captured")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="non-drag events should pass through")
            assert_drop_gate(client, "external", expected=True, reason="external file drags should be captured")
            assert_drop_gate(client, "local", expected=True, reason="local file drags should be captured")
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_portal_gate(client, event, expected=False, reason="file drag should not trigger portal pass-through policy")
            assert_sidebar_gate(client, "active", expected=False, reason="file drag is not sidebar reorder payload")
            assert_sidebar_gate(client, "inactive", expected=False, reason="inactive sidebar drag state")

            client.seed_drag_pasteboard_types(["fileurl", "tabtransfer"])
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="fileurl+tabtransfer must pass through")
            assert_drop_gate(client, "external", expected=False, reason="fileurl+tabtransfer must pass through")
            assert_drop_gate(client, "local", expected=False, reason="fileurl+tabtransfer must pass through")
            for event in PORTAL_PASS_THROUGH_EVENTS:
                assert_portal_gate(client, event, expected=True, reason="mixed fileurl+tabtransfer should still pass through portal")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_portal_gate(client, event, expected=False, reason="mixed payload must not hijack non-drag portal events")
            assert_sidebar_gate(client, "active", expected=False, reason="tabtransfer mix is not sidebar reorder payload")
            assert_sidebar_gate(client, "inactive", expected=False, reason="inactive sidebar drag state")

            client.seed_drag_pasteboard_types(["fileurl", "sidebarreorder"])
            for event in DRAG_EVENTS + NON_DRAG_EVENTS + ["none"]:
                assert_gate(client, event, expected=False, reason="fileurl+sidebarreorder must pass through")
            assert_drop_gate(client, "external", expected=False, reason="fileurl+sidebarreorder must pass through")
            assert_drop_gate(client, "local", expected=False, reason="fileurl+sidebarreorder must pass through")
            for event in PORTAL_PASS_THROUGH_EVENTS:
                assert_portal_gate(client, event, expected=True, reason="mixed fileurl+sidebarreorder should still pass through portal")
            for event in NON_DRAG_EVENTS + ["none"]:
                assert_portal_gate(client, event, expected=False, reason="mixed sidebar payload must not hijack non-drag portal events")
            assert_sidebar_gate(client, "active", expected=True, reason="sidebar reorder mix should keep sidebar outside overlay active")
            assert_sidebar_gate(client, "inactive", expected=False, reason="inactive sidebar drag state")

            print("PASS: drag routing policy matrix preserves bonsplit/sidebar drags and external file-drop behavior")
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
