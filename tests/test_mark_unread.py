#!/usr/bin/env python3
"""
E2E tests for the Mark as Unread feature.

Usage:
    CMUX_TAG=mark-unread python3 tests/test_mark_unread.py

Requirements:
    - cmux must be running with the tagged debug build
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux import cmux, cmuxError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def test_mark_unread_basic(client: cmux) -> TestResult:
    """Mark current tab as unread, verify state, then mark read."""
    result = TestResult("Basic mark unread / read")
    try:
        # Start clean
        state = client.tab_unread_state()
        if state != "read":
            client.mark_read()

        # Mark unread
        client.mark_unread()
        state = client.tab_unread_state()
        if state != "unread":
            result.failure(f"Expected 'unread' after mark_unread, got '{state}'")
            return result

        # Mark read
        client.mark_read()
        state = client.tab_unread_state()
        if state != "read":
            result.failure(f"Expected 'read' after mark_read, got '{state}'")
            return result

        result.success("Mark unread/read toggles correctly")
    except Exception as e:
        result.failure(str(e))
    return result


def test_mark_unread_by_index(client: cmux) -> TestResult:
    """Mark a specific tab by index as unread."""
    result = TestResult("Mark unread by tab index")
    try:
        tabs = client.list_tabs()
        if len(tabs) < 1:
            result.failure("Need at least 1 tab")
            return result

        # Mark tab 0 unread
        client.mark_unread(0)
        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread' for tab 0, got '{state}'")
            return result

        # Clean up
        client.mark_read(0)
        result.success("Mark unread by index works")
    except Exception as e:
        result.failure(str(e))
    return result


def test_mark_unread_clears_on_tab_switch(client: cmux) -> TestResult:
    """Mark tab as unread, switch away and back — should clear."""
    result = TestResult("Clears on tab switch")
    try:
        tabs = client.list_tabs()
        if len(tabs) < 2:
            # Create a second tab
            client.new_tab()
            time.sleep(0.3)
            tabs = client.list_tabs()

        if len(tabs) < 2:
            result.failure("Need at least 2 tabs")
            return result

        # Ensure app is considered active (needed for markFocusedPanelReadIfActive)
        client.set_app_focus(True)

        # Select tab 0 and mark unread
        client.select_tab(0)
        time.sleep(0.2)
        client.mark_unread(0)
        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread' for tab 0 after marking, got '{state}'")
            return result

        # Wait past the grace period so tab switch will clear it
        time.sleep(1.1)

        # Switch to tab 1
        client.select_tab(1)
        time.sleep(0.2)

        # Switch back to tab 0 — should clear the manual unread
        client.select_tab(0)
        time.sleep(0.3)

        state = client.tab_unread_state(0)
        if state != "read":
            result.failure(f"Expected 'read' after switching back, got '{state}'")
            return result

        result.success("Manual unread cleared on tab switch")
    except Exception as e:
        result.failure(str(e))
    finally:
        try:
            client.set_app_focus(None)
        except Exception:
            pass
    return result


def test_mark_unread_persists_within_tab(client: cmux) -> TestResult:
    """Mark tab unread, click split pane in same tab — should persist."""
    result = TestResult("Persists within tab (split pane click)")
    try:
        tabs = client.list_tabs()
        if len(tabs) < 1:
            result.failure("Need at least 1 tab")
            return result

        # Select tab 0
        client.select_tab(0)
        time.sleep(0.2)

        # Create a split if we don't have one
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            client.new_split("right")
            time.sleep(0.3)
            surfaces = client.list_surfaces()

        if len(surfaces) < 2:
            result.failure("Need at least 2 surfaces")
            return result

        # Mark unread
        client.mark_unread(0)
        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread' after marking, got '{state}'")
            return result

        # Focus a different surface in the same tab
        unfocused = [s for s in surfaces if not s[2]]
        if unfocused:
            client.focus_surface(unfocused[0][0])
            time.sleep(0.2)

        # Should still be unread
        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread' after split pane focus, got '{state}'")
            return result

        # Clean up
        client.mark_read(0)
        result.success("Manual unread persists across split pane focus")
    except Exception as e:
        result.failure(str(e))
    return result


def test_mark_unread_no_flash(client: cmux) -> TestResult:
    """Mark as unread should NOT trigger a flash (flash only on dismiss)."""
    result = TestResult("No flash on mark unread")
    try:
        client.select_tab(0)
        time.sleep(0.2)
        client.reset_flash_counts()

        surfaces = client.list_surfaces()
        focused = [s for s in surfaces if s[2]]
        if not focused:
            result.failure("No focused surface")
            return result

        surface_idx = focused[0][0]
        before = client.flash_count(surface_idx)

        client.mark_unread(0)
        time.sleep(0.2)

        after = client.flash_count(surface_idx)
        if after != before:
            result.failure(f"Flash count changed: before={before}, after={after}")
            return result

        # Clean up
        client.mark_read(0)
        result.success("No flash fired on mark unread")
    except Exception as e:
        result.failure(str(e))
    return result


def test_mark_unread_clears_on_app_reactivate(client: cmux) -> TestResult:
    """Mark unread, simulate app deactivate/reactivate — should clear.

    The appWasDeactivated flag is set by applicationDidResignActive (the real
    NSApplication delegate method). simulate_app_active only triggers
    applicationDidBecomeActive. We need to trigger the resign path first via
    a raw socket command.
    """
    result = TestResult("Clears on app reactivate")
    try:
        client.set_app_focus(True)
        client.select_tab(0)
        time.sleep(0.2)

        client.mark_unread(0)
        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread' after marking, got '{state}'")
            return result

        # Wait past the grace period (1s) so the reactivate clear isn't suppressed
        time.sleep(1.1)

        # Simulate app resign (sets appWasDeactivated = true) then reactivate
        client._send_command("simulate_app_resign")
        time.sleep(0.1)
        client.simulate_app_active()
        time.sleep(0.2)

        state = client.tab_unread_state(0)
        if state != "read":
            result.failure(f"Expected 'read' after app reactivate, got '{state}'")
            return result

        client.set_app_focus(None)
        result.success("Manual unread cleared on app reactivate")
    except Exception as e:
        try:
            client.set_app_focus(None)
        except Exception:
            pass
        result.failure(str(e))
    return result


def test_mark_read_clears_both(client: cmux) -> TestResult:
    """Explicit mark-read clears both manual flag and notification unread."""
    result = TestResult("Mark read clears manual flag + notifications")
    try:
        # Disable app focus so notification doesn't auto-dismiss
        client.set_app_focus(False)
        time.sleep(0.1)

        client.select_tab(0)
        time.sleep(0.2)

        # Create a notification and mark tab unread
        client.notify("Test notification")
        time.sleep(0.2)
        client.mark_unread(0)

        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread', got '{state}'")
            return result

        notifs = client.list_notifications()
        unread_count = sum(1 for n in notifs if not n["is_read"])
        if unread_count == 0:
            result.failure("Expected at least 1 unread notification")
            return result

        # Mark read — should clear both
        client.mark_read(0)
        state = client.tab_unread_state(0)
        if state != "read":
            result.failure(f"Expected 'read' after mark_read, got '{state}'")
            return result

        # Clean up
        client.clear_notifications()
        client.set_app_focus(None)
        result.success("Mark read clears both manual flag and notifications")
    except Exception as e:
        try:
            client.set_app_focus(None)
            client.clear_notifications()
        except Exception:
            pass
        result.failure(str(e))
    return result


def test_mark_unread_other_tab(client: cmux) -> TestResult:
    """Mark a non-selected tab as unread — should persist (no auto-clear)."""
    result = TestResult("Non-selected tab stays unread")
    try:
        tabs = client.list_tabs()
        if len(tabs) < 2:
            client.new_tab()
            time.sleep(0.3)
            tabs = client.list_tabs()

        if len(tabs) < 2:
            result.failure("Need at least 2 tabs")
            return result

        # Select tab 1, mark tab 0 unread
        client.select_tab(1)
        time.sleep(0.2)
        client.mark_unread(0)
        time.sleep(0.2)

        state = client.tab_unread_state(0)
        if state != "unread":
            result.failure(f"Expected 'unread' for non-selected tab, got '{state}'")
            return result

        # Clean up
        client.mark_read(0)
        client.select_tab(0)
        result.success("Non-selected tab stays unread")
    except Exception as e:
        result.failure(str(e))
    return result


def main():
    tests = [
        test_mark_unread_basic,
        test_mark_unread_by_index,
        test_mark_unread_clears_on_tab_switch,
        test_mark_unread_persists_within_tab,
        test_mark_unread_no_flash,
        test_mark_unread_clears_on_app_reactivate,
        test_mark_read_clears_both,
        test_mark_unread_other_tab,
    ]

    print("=" * 60)
    print("Mark as Unread — E2E Tests")
    print("=" * 60)

    client = cmux()
    try:
        client.connect()
        print(f"Connected to {client.socket_path}")
    except cmuxError as e:
        print(f"FATAL: {e}")
        sys.exit(1)

    results = []
    for test_fn in tests:
        r = test_fn(client)
        results.append(r)
        status = "PASS" if r.passed else "FAIL"
        detail = f" — {r.message}" if r.message else ""
        print(f"  [{status}] {r.name}{detail}")

    client.close()

    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    print()
    print(f"Results: {passed} passed, {failed} failed out of {len(results)}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
