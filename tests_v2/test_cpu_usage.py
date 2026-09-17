#!/usr/bin/env python3
"""
CPU usage test for cmux.

This test monitors cmux's CPU usage during idle periods to catch
performance regressions like runaway animations or continuous view updates.

Run this test after launching cmux:
    python3 tests/test_cpu_usage.py

The test will fail if idle CPU is *sustained* above threshold.
"""

from __future__ import annotations

import subprocess
import sys
import time
import re
import statistics
from pathlib import Path
from typing import List, Optional


# Maximum acceptable CPU usage during idle (percentage)
MAX_IDLE_CPU_PERCENT = 15.0

# How long to wait for app to settle before measuring (seconds)
SETTLE_TIME = 2.0

# Optional pre-check: wait for CPU to calm down before taking the idle sample.
# This reduces startup/transient flakiness while still preserving regression signal.
IDLE_PRECHECK_MAX_WAIT = 20.0
IDLE_PRECHECK_THRESHOLD = 20.0
IDLE_PRECHECK_CONSECUTIVE = 4

# Duration to monitor CPU usage (seconds)
MONITOR_DURATION = 5.0

# Sampling interval for CPU checks (seconds)
SAMPLE_INTERVAL = 0.5

# Patterns that indicate performance issues in sample output
SUSPICIOUS_PATTERNS = [
    r"body\.getter.*\d{3,}",  # View body getter called 100+ times
    r"repeatForever",  # Runaway animations
    r"TimelineView.*animation.*\d{3,}",  # Unpaused timeline views
]


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


def sample_process(pid: int, duration: int = 2) -> str:
    """Sample a process and return the output."""
    result = subprocess.run(
        ["sample", str(pid), str(duration)],
        capture_output=True,
        text=True,
    )
    return result.stdout + result.stderr


def check_sample_for_issues(sample_output: str) -> List[str]:
    """Check sample output for suspicious patterns."""
    issues = []
    for pattern in SUSPICIOUS_PATTERNS:
        if re.search(pattern, sample_output):
            issues.append(f"Found suspicious pattern: {pattern}")
    return issues


def monitor_cpu_usage(pid: int, duration: float, interval: float) -> List[float]:
    """Monitor CPU usage over a period and return all readings."""
    readings = []
    start = time.time()
    while time.time() - start < duration:
        cpu = get_cpu_usage(pid)
        readings.append(cpu)
        time.sleep(interval)
    return readings


def wait_for_idle_precheck(pid: int) -> bool:
    """Wait for a short streak of lower CPU readings before formal measurement."""
    deadline = time.time() + IDLE_PRECHECK_MAX_WAIT
    streak = 0
    while time.time() < deadline:
        cpu = get_cpu_usage(pid)
        if cpu <= IDLE_PRECHECK_THRESHOLD:
            streak += 1
            if streak >= IDLE_PRECHECK_CONSECUTIVE:
                return True
        else:
            streak = 0
        time.sleep(SAMPLE_INTERVAL)
    return False


def main():
    print("=" * 60)
    print("cmux CPU Usage Test")
    print("=" * 60)

    # Find cmux process
    pid = get_cmux_pid()
    if pid is None:
        print("\n❌ SKIP: cmux is not running")
        print("Start cmux and run this test again.")
        return 0  # Not a failure, just skip

    print(f"\nFound cmux process: PID {pid}")

    # Wait for app to settle
    print(f"Waiting {SETTLE_TIME}s for app to settle...")
    time.sleep(SETTLE_TIME)

    print(
        f"Waiting for idle precheck (<= {IDLE_PRECHECK_THRESHOLD:.1f}% "
        f"for {IDLE_PRECHECK_CONSECUTIVE} samples, timeout {IDLE_PRECHECK_MAX_WAIT:.1f}s)..."
    )
    if not wait_for_idle_precheck(pid):
        print("  ⚠️ Precheck timeout; continuing with measurement anyway")
    else:
        print("  ✓ Idle precheck passed")

    # Monitor CPU usage
    print(f"Monitoring CPU usage for {MONITOR_DURATION}s...")
    readings = monitor_cpu_usage(pid, MONITOR_DURATION, SAMPLE_INTERVAL)

    avg_cpu = sum(readings) / len(readings) if readings else 0.0
    max_cpu = max(readings) if readings else 0.0
    min_cpu = min(readings) if readings else 0.0
    median_cpu = statistics.median(readings) if readings else 0.0
    over_threshold = sum(1 for r in readings if r > MAX_IDLE_CPU_PERCENT)

    print("\nCPU Usage Results:")
    print(f"  Average: {avg_cpu:.1f}%")
    print(f"  Median:  {median_cpu:.1f}%")
    print(f"  Max:     {max_cpu:.1f}%")
    print(f"  Min:     {min_cpu:.1f}%")
    print(f"  Samples: {len(readings)}")
    print(f"  >{MAX_IDLE_CPU_PERCENT:.1f}%: {over_threshold}/{len(readings)}")

    # Treat failures as sustained-idle regressions, not single transient spikes.
    sustained_high = over_threshold >= ((len(readings) + 1) // 2)
    if median_cpu > MAX_IDLE_CPU_PERCENT or sustained_high:
        reason = []
        if median_cpu > MAX_IDLE_CPU_PERCENT:
            reason.append(f"median {median_cpu:.1f}% > {MAX_IDLE_CPU_PERCENT:.1f}%")
        if sustained_high:
            reason.append(f"{over_threshold}/{len(readings)} samples above threshold")
        print(f"\n❌ FAIL: Sustained high idle CPU detected ({'; '.join(reason)})")

        # Take a sample to diagnose
        print("\nTaking process sample for diagnosis...")
        sample_output = sample_process(pid, 2)

        # Check for known issues
        issues = check_sample_for_issues(sample_output)
        if issues:
            print("\nDiagnostic findings:")
            for issue in issues:
                print(f"  - {issue}")

        # Save sample for debugging
        sample_file = Path("/tmp/cmux_cpu_test_sample.txt")
        sample_file.write_text(sample_output)
        print(f"\nFull sample saved to: {sample_file}")

        # Show top functions from sample
        print("\nTop functions in sample (look for .body.getter or Animation):")
        lines = sample_output.split("\n")
        relevant_lines = [
            l for l in lines
            if "cmux" in l and ("body" in l or "Animation" in l or "Timer" in l)
        ][:10]
        for line in relevant_lines:
            print(f"  {line.strip()[:100]}")

        return 1

    print("\n✅ PASS: CPU usage is within acceptable range")
    return 0


if __name__ == "__main__":
    sys.exit(main())
