#!/usr/bin/env python3
"""
CPU usage tests for notification scenarios.

Tests that CPU usage stays reasonable when:
1. Notifications arrive
2. Notifications popover is opened and closed
3. Multiple notifications arrive in sequence

Usage:
    python3 tests/test_cpu_notifications.py

Requires cmuxterm to be running with socket control enabled.
"""

from __future__ import annotations

import subprocess
import sys
import time
import os
from typing import List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


# Maximum acceptable CPU usage during idle (after notifications)
MAX_IDLE_CPU_PERCENT = 20.0

# Maximum acceptable CPU usage right after notification burst
MAX_POST_NOTIFICATION_CPU_PERCENT = 30.0

# How long to wait for app to settle (seconds)
SETTLE_TIME = 2.0

# Duration to monitor CPU (seconds)
MONITOR_DURATION = 3.0


def get_cmuxterm_pid() -> Optional[int]:
    """Get the PID of the running cmuxterm process."""
    result = subprocess.run(
        ["pgrep", "-f", r"cmuxterm\.app/Contents/MacOS/cmuxterm$"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # Try DEV build
        result = subprocess.run(
            ["pgrep", "-f", r"cmuxterm DEV\.app/Contents/MacOS/cmuxterm"],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        return None
    pids = result.stdout.strip().split("\n")
    return int(pids[0]) if pids and pids[0] else None


def get_cpu_usage(pid: int) -> float:
    """Get current CPU usage percentage for a process."""
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "%cpu="],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return 0.0
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def monitor_cpu(pid: int, duration: float, interval: float = 0.5) -> List[float]:
    """Monitor CPU usage over a period."""
    readings = []
    start = time.time()
    while time.time() - start < duration:
        readings.append(get_cpu_usage(pid))
        time.sleep(interval)
    return readings


def test_cpu_after_notification_burst(client: cmux, pid: int) -> tuple[bool, str]:
    """
    Test that CPU returns to normal after a burst of notifications.
    """
    # Clear any existing notifications
    try:
        client.clear_notifications()
    except cmuxError:
        pass
    time.sleep(0.5)

    # Send a burst of notifications
    for i in range(5):
        try:
            client.notify(f"Test notification {i+1}")
        except cmuxError:
            pass
        time.sleep(0.1)

    # Wait for processing
    time.sleep(1.0)

    # Monitor CPU
    readings = monitor_cpu(pid, MONITOR_DURATION)
    avg_cpu = sum(readings) / len(readings) if readings else 0

    # Clean up
    try:
        client.clear_notifications()
    except cmuxError:
        pass

    if avg_cpu > MAX_POST_NOTIFICATION_CPU_PERCENT:
        return False, f"CPU {avg_cpu:.1f}% exceeds {MAX_POST_NOTIFICATION_CPU_PERCENT}% after notification burst"

    return True, f"CPU {avg_cpu:.1f}% is acceptable after notification burst"


def test_cpu_after_popover_close(client: cmux, pid: int) -> tuple[bool, str]:
    """
    Test that CPU returns to normal after opening and closing the notifications popover.

    This tests that the popover's SwiftUI view is properly cleaned up when closed.
    """
    # Create some notifications first
    try:
        client.clear_notifications()
    except cmuxError:
        pass
    for i in range(3):
        try:
            client.notify(f"Popover test {i+1}")
        except cmuxError:
            pass
        time.sleep(0.1)
    time.sleep(0.5)

    # Simulate opening and closing the popover via keyboard shortcut
    # We can't directly control the popover, but we can toggle it
    subprocess.run([
        "osascript", "-e",
        'tell application "System Events" to keystroke "i" using {command down, shift down}'
    ], capture_output=True)
    time.sleep(0.5)

    # Close it
    subprocess.run([
        "osascript", "-e",
        'tell application "System Events" to keystroke "i" using {command down, shift down}'
    ], capture_output=True)
    time.sleep(1.0)

    # Monitor CPU - should be low now
    readings = monitor_cpu(pid, MONITOR_DURATION)
    avg_cpu = sum(readings) / len(readings) if readings else 0

    # Clean up
    try:
        client.clear_notifications()
    except cmuxError:
        pass

    if avg_cpu > MAX_IDLE_CPU_PERCENT:
        return False, f"CPU {avg_cpu:.1f}% exceeds {MAX_IDLE_CPU_PERCENT}% after closing popover"

    return True, f"CPU {avg_cpu:.1f}% is acceptable after closing popover"


def test_cpu_idle_with_notifications(client: cmux, pid: int) -> tuple[bool, str]:
    """
    Test that CPU stays low when notifications exist but popover is closed.
    """
    # Create notifications
    try:
        client.clear_notifications()
    except cmuxError:
        pass
    for i in range(3):
        try:
            client.notify(f"Idle test {i+1}")
        except cmuxError:
            pass
        time.sleep(0.2)

    # Wait for things to settle
    time.sleep(SETTLE_TIME)

    # Monitor CPU
    readings = monitor_cpu(pid, MONITOR_DURATION)
    avg_cpu = sum(readings) / len(readings) if readings else 0

    # Clean up
    try:
        client.clear_notifications()
    except cmuxError:
        pass

    if avg_cpu > MAX_IDLE_CPU_PERCENT:
        return False, f"CPU {avg_cpu:.1f}% exceeds {MAX_IDLE_CPU_PERCENT}% with notifications pending"

    return True, f"CPU {avg_cpu:.1f}% is acceptable with notifications pending"


def main():
    print("=" * 60)
    print("cmuxterm Notification CPU Tests")
    print("=" * 60)

    pid = get_cmuxterm_pid()
    if pid is None:
        print("\n❌ SKIP: cmuxterm is not running")
        return 0

    print(f"\nFound cmuxterm process: PID {pid}")

    # Try to connect to the socket
    socket_paths = ["/tmp/cmuxterm.sock", "/tmp/cmuxterm-debug.sock"]
    client = None
    for socket_path in socket_paths:
        if os.path.exists(socket_path):
            try:
                client = cmux(socket_path)
                client.connect()
                print(f"Connected to {socket_path}")
                break
            except cmuxError:
                continue

    if client is None:
        print(f"\n❌ SKIP: Could not connect to cmuxterm socket")
        return 0

    results = []

    print("\nRunning tests...")

    # Test 1: CPU after notification burst
    print("\n[1/3] Testing CPU after notification burst...")
    passed, msg = test_cpu_after_notification_burst(client, pid)
    results.append(("CPU after notification burst", passed, msg))
    print(f"  {'✓' if passed else '✗'} {msg}")

    time.sleep(1)

    # Test 2: CPU after popover close
    print("\n[2/3] Testing CPU after popover open/close...")
    passed, msg = test_cpu_after_popover_close(client, pid)
    results.append(("CPU after popover close", passed, msg))
    print(f"  {'✓' if passed else '✗'} {msg}")

    time.sleep(1)

    # Test 3: CPU idle with pending notifications
    print("\n[3/3] Testing CPU idle with pending notifications...")
    passed, msg = test_cpu_idle_with_notifications(client, pid)
    results.append(("CPU idle with notifications", passed, msg))
    print(f"  {'✓' if passed else '✗'} {msg}")

    client.close()

    # Summary
    print("\n" + "=" * 60)
    print("Results:")
    all_passed = True
    for name, passed, msg in results:
        status = "PASS" if passed else "FAIL"
        print(f"  {status}: {name}")
        if not passed:
            all_passed = False

    if all_passed:
        print("\n✅ All notification CPU tests passed!")
        return 0
    else:
        print("\n❌ Some tests failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
