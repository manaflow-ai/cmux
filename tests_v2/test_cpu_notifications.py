#!/usr/bin/env python3
"""
CPU usage tests for notification scenarios.

Tests that CPU usage stays reasonable when:
1. Notifications arrive
2. Notifications popover is opened and closed
3. Multiple notifications arrive in sequence

Usage:
    python3 tests/test_cpu_notifications.py

Requires cmux to be running with socket control enabled.
"""

from __future__ import annotations

import subprocess
import sys
import time
import os
import statistics
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

# Sampling interval for CPU checks (seconds)
SAMPLE_INTERVAL = 0.5

# Optional pre-check: wait for CPU to calm down before taking the measurement.
# This reduces startup/transient flakiness while still preserving regression
# signal (mirrors tests_v2/test_cpu_usage.py).
IDLE_PRECHECK_MAX_WAIT = 20.0
IDLE_PRECHECK_CONSECUTIVE = 4


def get_cmux_pid() -> Optional[int]:
    """Get the PID of the running cmux process."""
    result = subprocess.run(
        ["pgrep", "-f", r"cmux\.app/Contents/MacOS/cmux$"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # Try DEV build
        result = subprocess.run(
            ["pgrep", "-f", r"cmux DEV\.app/Contents/MacOS/cmux"],
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


def wait_for_idle_precheck(pid: int, threshold: float) -> bool:
    """Wait for a short streak of CPU readings at or below threshold.

    Bounds startup/transient scheduling spikes so the formal measurement
    starts from a calm baseline. Returns True once a streak is observed, or
    False at the deadline (the caller still measures, so this only trims
    flakiness, it does not weaken the assertion).
    """
    deadline = time.time() + IDLE_PRECHECK_MAX_WAIT
    streak = 0
    while time.time() < deadline:
        cpu = get_cpu_usage(pid)
        if cpu <= threshold:
            streak += 1
            if streak >= IDLE_PRECHECK_CONSECUTIVE:
                return True
        else:
            streak = 0
        time.sleep(SAMPLE_INTERVAL)
    return False


def evaluate_cpu_readings(readings: List[float], threshold: float) -> tuple[bool, str]:
    """Decide pass/fail from CPU samples using median + sustained-majority.

    A single hot wall-clock window (background indexing, GC, scheduler spike)
    must not flip the result on otherwise-correct code, so we fail only when
    the MEDIAN exceeds threshold or a majority of samples are sustained above
    it. This mirrors tests_v2/test_cpu_usage.py and keeps real regression
    signal (a process actually spinning stays high across most samples).
    """
    if not readings:
        return False, "no CPU readings collected"
    median_cpu = statistics.median(readings)
    over_threshold = sum(1 for r in readings if r > threshold)
    sustained_high = over_threshold >= ((len(readings) + 1) // 2)
    summary = (
        f"median {median_cpu:.1f}% (avg {sum(readings) / len(readings):.1f}%, "
        f"max {max(readings):.1f}%, {over_threshold}/{len(readings)} > {threshold:.0f}%)"
    )
    if median_cpu > threshold or sustained_high:
        return False, summary
    return True, summary


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

    # Wait for processing, then for CPU to calm down before measuring.
    time.sleep(1.0)
    wait_for_idle_precheck(pid, MAX_POST_NOTIFICATION_CPU_PERCENT)

    # Monitor CPU
    readings = monitor_cpu(pid, MONITOR_DURATION)
    ok, summary = evaluate_cpu_readings(readings, MAX_POST_NOTIFICATION_CPU_PERCENT)

    # Clean up
    try:
        client.clear_notifications()
    except cmuxError:
        pass

    if not ok:
        return False, f"CPU {summary} exceeds {MAX_POST_NOTIFICATION_CPU_PERCENT}% after notification burst"

    return True, f"CPU {summary} is acceptable after notification burst"


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

    # Toggle the popover via our debug socket shortcut simulator (doesn't require Accessibility).
    # Default: Cmd+Shift+I (Show Notifications).
    try:
        client.simulate_shortcut("cmd+shift+i")
    except Exception:
        # Keep this test best-effort; if shortcut simulation is unavailable, fall back to osascript.
        subprocess.run([
            "osascript", "-e",
            'tell application "System Events" to keystroke "i" using {command down, shift down}'
        ], capture_output=True)
    time.sleep(0.5)

    # Close it
    try:
        client.simulate_shortcut("cmd+shift+i")
    except Exception:
        subprocess.run([
            "osascript", "-e",
            'tell application "System Events" to keystroke "i" using {command down, shift down}'
        ], capture_output=True)
    time.sleep(1.0)
    wait_for_idle_precheck(pid, MAX_IDLE_CPU_PERCENT)

    # Monitor CPU - should be low now
    readings = monitor_cpu(pid, MONITOR_DURATION)
    ok, summary = evaluate_cpu_readings(readings, MAX_IDLE_CPU_PERCENT)

    # Clean up
    try:
        client.clear_notifications()
    except cmuxError:
        pass

    if not ok:
        return False, f"CPU {summary} exceeds {MAX_IDLE_CPU_PERCENT}% after closing popover"

    return True, f"CPU {summary} is acceptable after closing popover"


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

    # Wait for things to settle, then for CPU to calm down before measuring.
    time.sleep(SETTLE_TIME)
    wait_for_idle_precheck(pid, MAX_IDLE_CPU_PERCENT)

    # Monitor CPU
    readings = monitor_cpu(pid, MONITOR_DURATION)
    ok, summary = evaluate_cpu_readings(readings, MAX_IDLE_CPU_PERCENT)

    # Clean up
    try:
        client.clear_notifications()
    except cmuxError:
        pass

    if not ok:
        return False, f"CPU {summary} exceeds {MAX_IDLE_CPU_PERCENT}% with notifications pending"

    return True, f"CPU {summary} is acceptable with notifications pending"


def main():
    print("=" * 60)
    print("cmux Notification CPU Tests")
    print("=" * 60)

    pid = get_cmux_pid()
    if pid is None:
        print("\n❌ SKIP: cmux is not running")
        return 0

    print(f"\nFound cmux process: PID {pid}")

    # Try to connect to the socket
    socket_paths = [
        os.path.expanduser("~/Library/Application Support/cmux/cmux.sock"),
        "/tmp/cmux.sock",
        "/tmp/cmux-debug.sock",
    ]
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
        print(f"\n❌ SKIP: Could not connect to cmux socket")
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
