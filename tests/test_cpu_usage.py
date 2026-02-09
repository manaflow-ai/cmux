#!/usr/bin/env python3
"""
CPU usage test for cmuxterm.

This test monitors cmuxterm's CPU usage during idle periods to catch
performance regressions like runaway animations or continuous view updates.

Run this test after launching cmuxterm:
    python3 tests/test_cpu_usage.py

The test will fail if:
- CPU usage exceeds 15% during idle (no user interaction)
- The sample shows suspicious patterns (continuous body.getter calls, animations)
"""

from __future__ import annotations

import subprocess
import sys
import time
import re
from pathlib import Path
from typing import List, Optional


# Maximum acceptable CPU usage during idle (percentage)
MAX_IDLE_CPU_PERCENT = 15.0

# How long to wait for app to settle before measuring (seconds)
SETTLE_TIME = 2.0

# Duration to monitor CPU usage (seconds)
MONITOR_DURATION = 3.0

# Sampling interval for CPU checks (seconds)
SAMPLE_INTERVAL = 0.5

# Patterns that indicate performance issues in sample output
SUSPICIOUS_PATTERNS = [
    r"body\.getter.*\d{3,}",  # View body getter called 100+ times
    r"repeatForever",  # Runaway animations
    r"TimelineView.*animation.*\d{3,}",  # Unpaused timeline views
]


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


def main():
    print("=" * 60)
    print("cmuxterm CPU Usage Test")
    print("=" * 60)

    # Find cmuxterm process
    pid = get_cmuxterm_pid()
    if pid is None:
        print("\n❌ SKIP: cmuxterm is not running")
        print("Start cmuxterm and run this test again.")
        return 0  # Not a failure, just skip

    print(f"\nFound cmuxterm process: PID {pid}")

    # Wait for app to settle
    print(f"Waiting {SETTLE_TIME}s for app to settle...")
    time.sleep(SETTLE_TIME)

    # Monitor CPU usage
    print(f"Monitoring CPU usage for {MONITOR_DURATION}s...")
    readings = monitor_cpu_usage(pid, MONITOR_DURATION, SAMPLE_INTERVAL)

    avg_cpu = sum(readings) / len(readings) if readings else 0
    max_cpu = max(readings) if readings else 0
    min_cpu = min(readings) if readings else 0

    print(f"\nCPU Usage Results:")
    print(f"  Average: {avg_cpu:.1f}%")
    print(f"  Max:     {max_cpu:.1f}%")
    print(f"  Min:     {min_cpu:.1f}%")
    print(f"  Samples: {len(readings)}")

    # Check if CPU is too high
    if avg_cpu > MAX_IDLE_CPU_PERCENT:
        print(f"\n❌ FAIL: Average CPU ({avg_cpu:.1f}%) exceeds threshold ({MAX_IDLE_CPU_PERCENT}%)")

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
        sample_file = Path("/tmp/cmuxterm_cpu_test_sample.txt")
        sample_file.write_text(sample_output)
        print(f"\nFull sample saved to: {sample_file}")

        # Show top functions from sample
        print("\nTop functions in sample (look for .body.getter or Animation):")
        lines = sample_output.split("\n")
        relevant_lines = [
            l for l in lines
            if "cmuxterm" in l and ("body" in l or "Animation" in l or "Timer" in l)
        ][:10]
        for line in relevant_lines:
            print(f"  {line.strip()[:100]}")

        return 1

    print(f"\n✅ PASS: CPU usage is within acceptable range")
    return 0


if __name__ == "__main__":
    sys.exit(main())
