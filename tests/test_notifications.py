#!/usr/bin/env python3
"""
Automated tests for notification focus/suppression behavior.

Usage:
    python3 test_notifications.py

Requirements:
    - cmux must be running with the socket controller enabled
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


def wait_for_notifications(client: cmux, expected: int, timeout: float = 2.0) -> list[dict]:
    start = time.time()
    while time.time() - start < timeout:
        items = client.list_notifications()
        if len(items) == expected:
            return items
        time.sleep(0.05)
    return client.list_notifications()


def ensure_two_surfaces(client: cmux) -> list[tuple[int, str, bool]]:
    surfaces = client.list_surfaces()
    if len(surfaces) < 2:
        client.new_split("right")
        time.sleep(0.1)
        surfaces = client.list_surfaces()
    return surfaces


def test_clear_prior_notifications(client: cmux) -> TestResult:
    result = TestResult("Clear Prior Panel Notifications")
    try:
        client.clear_notifications()
        client.set_app_focus(False)
        client.notify("first")
        time.sleep(0.1)
        client.notify("second")
        items = wait_for_notifications(client, 1)
        if len(items) != 1:
            result.failure(f"Expected 1 notification, got {len(items)}")
        elif items[0]["title"] != "second":
            result.failure(f"Expected latest title 'second', got '{items[0]['title']}'")
        else:
            result.success("Prior panel notifications cleared")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_suppress_when_focused(client: cmux) -> TestResult:
    result = TestResult("Suppress When App+Panel Focused")
    try:
        client.clear_notifications()
        client.set_app_focus(True)
        client.notify("focused")
        items = wait_for_notifications(client, 0)
        if len(items) == 0:
            result.success("Suppressed notification when focused")
        else:
            result.failure(f"Expected 0 notifications, got {len(items)}")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_not_suppressed_when_inactive(client: cmux) -> TestResult:
    result = TestResult("Allow When App Inactive")
    try:
        client.clear_notifications()
        client.set_app_focus(False)
        client.notify("inactive")
        items = wait_for_notifications(client, 1)
        if len(items) != 1:
            result.failure(f"Expected 1 notification, got {len(items)}")
        elif items[0]["is_read"]:
            result.failure("Expected notification to be unread")
        else:
            result.success("Notification stored when app inactive")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_mark_read_on_focus_change(client: cmux) -> TestResult:
    result = TestResult("Mark Read On Panel Focus")
    try:
        client.clear_notifications()
        surfaces = ensure_two_surfaces(client)
        focused = next((s for s in surfaces if s[2]), None)
        other = next((s for s in surfaces if not s[2]), None)
        if focused is None or other is None:
            result.failure("Unable to identify focused and unfocused surfaces")
            return result

        client.set_app_focus(False)
        client.notify_surface(other[0], "focusread")
        time.sleep(0.1)

        client.set_app_focus(True)
        client.focus_surface(other[0])
        time.sleep(0.1)

        items = client.list_notifications()
        target = next((n for n in items if n["surface_id"] == other[1]), None)
        if target is None:
            result.failure("Expected notification for target surface")
        elif not target["is_read"]:
            result.failure("Expected notification to be marked read on focus")
        else:
            result.success("Notification marked read on focus")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_mark_read_on_app_active(client: cmux) -> TestResult:
    result = TestResult("Mark Read On App Active")
    try:
        client.clear_notifications()
        client.set_app_focus(False)
        client.notify("activate")
        time.sleep(0.1)

        items = client.list_notifications()
        if not items or items[0]["is_read"]:
            result.failure("Expected unread notification before activation")
            return result

        client.simulate_app_active()
        time.sleep(0.1)

        items = client.list_notifications()
        if not items:
            result.failure("Expected notification to remain after activation")
        elif not items[0]["is_read"]:
            result.failure("Expected notification to be marked read on app active")
        else:
            result.success("Notification marked read on app active")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_mark_read_on_tab_switch(client: cmux) -> TestResult:
    result = TestResult("Mark Read On Tab Switch")
    try:
        client.clear_notifications()
        client.set_app_focus(False)
        tab1 = client.current_tab()
        client.notify("tabswitch")
        time.sleep(0.1)

        tab2 = client.new_tab()
        time.sleep(0.1)

        client.set_app_focus(True)
        client.select_tab(tab1)
        time.sleep(0.1)

        items = client.list_notifications()
        target = next((n for n in items if n["tab_id"] == tab1), None)
        if target is None:
            result.failure("Expected notification for original tab")
        elif not target["is_read"]:
            result.failure("Expected notification to be marked read on tab switch")
        else:
            result.success("Notification marked read on tab switch")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_no_flash_on_tab_switch(client: cmux) -> TestResult:
    result = TestResult("No Flash On Tab Switch")
    try:
        client.clear_notifications()
        client.reset_flash_counts()

        tab1 = client.current_tab()
        surfaces = client.list_surfaces()
        focused = next((s for s in surfaces if s[2]), None)
        if focused is None:
            result.failure("Unable to identify focused surface")
            return result

        client.set_app_focus(False)
        client.notify("tabswitchflash")
        time.sleep(0.1)

        client.new_tab()
        time.sleep(0.1)

        client.set_app_focus(True)
        client.select_tab(tab1)
        time.sleep(0.2)

        count = client.flash_count(focused[1])
        if count != 0:
            result.failure(f"Expected flash count 0, got {count}")
        else:
            result.success("No flash triggered on tab switch")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_focus_on_notification_click(client: cmux) -> TestResult:
    result = TestResult("Focus On Notification Click")
    try:
        client.clear_notifications()
        client.reset_flash_counts()

        surfaces = ensure_two_surfaces(client)
        focused = next((s for s in surfaces if s[2]), None)
        other = next((s for s in surfaces if not s[2]), None)
        if focused is None or other is None:
            result.failure("Unable to identify focused and unfocused surfaces")
            return result

        client.set_app_focus(False)
        client.notify_surface(other[0], "notifyfocus")
        time.sleep(0.1)

        client.set_app_focus(True)
        tab_id = client.current_tab()
        client.focus_notification(tab_id, other[0])
        time.sleep(0.2)

        surfaces = client.list_surfaces()
        target = next((s for s in surfaces if s[1] == other[1]), None)
        if target is None or not target[2]:
            result.failure("Expected notification surface to be focused")
            return result

        count = client.flash_count(other[1])
        if count < 1:
            result.failure(f"Expected flash count >= 1, got {count}")
        else:
            result.success("Notification click focuses and flashes panel")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_restore_focus_on_tab_switch(client: cmux) -> TestResult:
    result = TestResult("Restore Focus On Tab Switch")
    try:
        client.clear_notifications()
        client.set_app_focus(True)

        surfaces = ensure_two_surfaces(client)
        focused = next((s for s in surfaces if s[2]), None)
        other = next((s for s in surfaces if not s[2]), None)
        if focused is None or other is None:
            result.failure("Unable to identify focused and unfocused surfaces")
            return result

        client.focus_surface(other[0])
        time.sleep(0.1)

        tab1 = client.current_tab()
        client.new_tab()
        time.sleep(0.1)

        client.select_tab(tab1)
        time.sleep(0.2)

        surfaces = client.list_surfaces()
        target = next((s for s in surfaces if s[1] == other[1]), None)
        if target is None:
            result.failure("Unable to find previously focused surface")
        elif not target[2]:
            result.failure("Expected previously focused surface to be focused after tab switch")
        else:
            result.success("Restored last focused surface after tab switch")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def run_tests() -> int:
    results = []
    with cmux() as client:
        results.append(test_clear_prior_notifications(client))
        results.append(test_suppress_when_focused(client))
        results.append(test_not_suppressed_when_inactive(client))
        results.append(test_mark_read_on_focus_change(client))
        results.append(test_mark_read_on_app_active(client))
        results.append(test_mark_read_on_tab_switch(client))
        results.append(test_no_flash_on_tab_switch(client))
        results.append(test_focus_on_notification_click(client))
        results.append(test_restore_focus_on_tab_switch(client))
        client.set_app_focus(None)
        client.clear_notifications()

    print("\nNotification Tests:")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        msg = f" - {r.message}" if r.message else ""
        print(f"{status}: {r.name}{msg}")

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    if passed == total:
        print("\n🎉 All notification tests passed!")
        return 0
    print(f"\n⚠️  {total - passed} test(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(run_tests())
