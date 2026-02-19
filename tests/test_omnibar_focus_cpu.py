#!/usr/bin/env python3
"""
Regression test: pressing Cmd+L to focus the browser omnibar must not cause
a CPU spike from an infinite makeFirstResponder loop.

Background: commit 2d64ecfc wrapped the omnibar's makeFirstResponder call in
DispatchQueue.main.async without a re-dispatch guard. Each async
makeFirstResponder triggers SwiftUI's FirstResponderObserver → view graph
re-evaluation → updateNSView → another async makeFirstResponder → ∞ loop,
pegging the main thread at 100% CPU.

This test opens a browser panel, triggers Cmd+L, and asserts that CPU stays
below threshold for a few seconds afterward.

Requires:
  - cmux running (debug build)
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError

MAX_CPU_PERCENT = 30.0
SETTLE_AFTER_FOCUS_S = 1.5
MONITOR_DURATION_S = 3.0
SAMPLE_INTERVAL_S = 0.5


def get_cmux_pid() -> int | None:
    socket_path = os.environ.get("CMUX_SOCKET_PATH")
    if not socket_path:
        try:
            socket_path = cmux().socket_path
        except Exception:
            socket_path = None

    if socket_path and os.path.exists(socket_path):
        result = subprocess.run(
            ["lsof", "-t", socket_path],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    pid = int(line)
                except ValueError:
                    continue
                if pid != os.getpid():
                    return pid

    result = subprocess.run(
        ["pgrep", "-f", r"cmux\.app/Contents/MacOS/cmux$"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        result = subprocess.run(
            ["pgrep", "-f", r"cmux DEV\.app/Contents/MacOS/cmux"],
            capture_output=True, text=True,
        )
    if result.returncode != 0:
        return None
    pids = result.stdout.strip().split("\n")
    return int(pids[0]) if pids and pids[0] else None


def get_cpu(pid: int) -> float:
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "%cpu="],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return 0.0
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def monitor_cpu(pid: int, duration: float, interval: float) -> list[float]:
    readings: list[float] = []
    start = time.time()
    while time.time() - start < duration:
        readings.append(get_cpu(pid))
        time.sleep(interval)
    return readings


def main() -> int:
    print("=" * 60)
    print("Omnibar Cmd+L Focus CPU Regression Test")
    print("=" * 60)

    pid = get_cmux_pid()
    if pid is None:
        print("\nSKIP: cmux is not running")
        return 0

    client = cmux()
    client.connect()

    try:
        # Create a workspace with a browser panel.
        ws_id = client.new_workspace()
        client.select_workspace(ws_id)
        time.sleep(0.5)
        browser_id = client.new_surface(panel_type="browser", url="https://example.com")
        time.sleep(3.0)  # let page load and panel stabilize

        # Focus the browser webview first.
        client.focus_surface_by_panel(browser_id)
        time.sleep(0.3)
        client.focus_webview(browser_id)
        time.sleep(0.5)

        # Baseline CPU reading.
        baseline = get_cpu(pid)
        print(f"\nBaseline CPU: {baseline:.1f}%")

        # Trigger Cmd+L to focus the omnibar.
        print("Simulating Cmd+L...")
        client.simulate_shortcut("cmd+l")
        time.sleep(SETTLE_AFTER_FOCUS_S)

        # Monitor CPU after Cmd+L.
        print(f"Monitoring CPU for {MONITOR_DURATION_S}s...")
        readings = monitor_cpu(pid, MONITOR_DURATION_S, SAMPLE_INTERVAL_S)

        avg_cpu = sum(readings) / len(readings) if readings else 0
        max_cpu = max(readings) if readings else 0
        print(f"\nPost Cmd+L CPU:")
        print(f"  Average: {avg_cpu:.1f}%")
        print(f"  Max:     {max_cpu:.1f}%")
        print(f"  Samples: {readings}")

        # Test: repeat Cmd+L while already focused (should also be safe).
        print("\nSimulating Cmd+L again (already focused)...")
        client.simulate_shortcut("cmd+l")
        time.sleep(SETTLE_AFTER_FOCUS_S)
        readings2 = monitor_cpu(pid, MONITOR_DURATION_S, SAMPLE_INTERVAL_S)
        avg_cpu2 = sum(readings2) / len(readings2) if readings2 else 0
        max_cpu2 = max(readings2) if readings2 else 0
        print(f"  Average: {avg_cpu2:.1f}%")
        print(f"  Max:     {max_cpu2:.1f}%")

        # Verdict.
        worst = max(max_cpu, max_cpu2)
        if worst > MAX_CPU_PERCENT:
            print(f"\nFAIL: CPU peaked at {worst:.1f}% (threshold {MAX_CPU_PERCENT}%)")
            print("Likely infinite makeFirstResponder loop in omnibar updateNSView.")

            # Take a diagnostic sample.
            sample = subprocess.run(
                ["sample", str(pid), "2"],
                capture_output=True, text=True,
            )
            sample_text = sample.stdout + sample.stderr
            if "updateNSView" in sample_text or "makeFirstResponder" in sample_text:
                print("  Confirmed: sample shows updateNSView / makeFirstResponder loop")
            sample_path = f"/tmp/cmux_omnibar_focus_cpu_{pid}.txt"
            with open(sample_path, "w") as f:
                f.write(sample_text)
            print(f"  Sample saved to {sample_path}")
            return 1

        print(f"\nPASS: CPU stayed within bounds (peak {worst:.1f}%)")
        return 0

    finally:
        # Cleanup: close the test workspace.
        try:
            client.close_workspace(ws_id)
        except Exception:
            pass
        client.close()


if __name__ == "__main__":
    sys.exit(main())
