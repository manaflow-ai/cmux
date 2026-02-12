#!/usr/bin/env python3
"""
Regression test for blank screen on macOS 26 (Tahoe).

Verifies that the terminal actually renders content by:
1. Reading the screen to check for a shell prompt (non-empty)
2. Sending a command and verifying it appears on screen

Usage:
    python3 test_blank_screen.py

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


def test_screen_not_blank(client: cmux) -> TestResult:
    """Test that the terminal has some visible content (shell prompt)."""
    result = TestResult("Screen not blank")
    try:
        screen = client.read_screen()
        if screen.startswith("ERROR:"):
            result.failure(f"read_screen returned error: {screen}")
            return result

        stripped = screen.strip()
        if not stripped:
            result.failure("Screen is blank — no visible content")
        else:
            preview = stripped[:80].replace("\n", "\\n")
            result.success(f"Screen has content: {preview}...")
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def test_render_marker(client: cmux) -> TestResult:
    """Test that echoed text actually renders on screen."""
    result = TestResult("Render marker")
    marker = "RENDER_TEST_MARKER_12345"

    try:
        client.send(f"echo {marker}\n")
        time.sleep(1.0)

        screen = client.read_screen()
        if screen.startswith("ERROR:"):
            result.failure(f"read_screen returned error: {screen}")
            return result

        if marker in screen:
            result.success(f"Marker '{marker}' found on screen")
        else:
            preview = screen.strip()[:200].replace("\n", "\\n")
            result.failure(
                f"Marker '{marker}' not found on screen. "
                f"Screen content: {preview}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def run_tests():
    print("=" * 60)
    print("Blank Screen Regression Test")
    print("=" * 60)
    print()

    socket_path = cmux().socket_path
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmux is running.")
        print("Tip: set CMUX_TAG=<tag> or CMUX_SOCKET_PATH=<path> to target a tagged instance.")
        return 1

    results = []

    try:
        with cmux() as client:
            print("Testing connection...")
            if not client.ping():
                print("  FAIL: Ping failed")
                return 1
            print("  PASS: Connected")
            print()

            print("Testing screen is not blank...")
            results.append(test_screen_not_blank(client))
            status = "PASS" if results[-1].passed else "FAIL"
            print(f"  {status}: {results[-1].message}")
            print()

            time.sleep(0.5)

            print("Testing render marker...")
            results.append(test_render_marker(client))
            status = "PASS" if results[-1].passed else "FAIL"
            print(f"  {status}: {results[-1].message}")
            print()

    except cmuxError as e:
        print(f"Error: {e}")
        return 1

    print("=" * 60)
    print("Results")
    print("=" * 60)

    passed = sum(1 for r in results if r.passed)
    total = len(results)

    for r in results:
        status = "PASS" if r.passed else "FAIL"
        print(f"  {r.name}: {status}")
        if not r.passed and r.message:
            print(f"      {r.message}")

    print()
    print(f"Passed: {passed}/{total}")

    if passed == total:
        print("\nAll tests passed!")
        return 0
    else:
        print(f"\n{total - passed} test(s) failed")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
