#!/usr/bin/env python3
"""
Interactive test for Ctrl+C and Ctrl+D in cmux terminal.

This script tests that control signals are properly handled.
Run this script inside the cmux terminal.

Tests:
1. Ctrl+C (SIGINT) - Should interrupt a running process
2. Ctrl+D (EOF) - Should signal end-of-file on stdin

Usage:
    python3 test_ctrl_interactive.py
"""

import signal
import sys
import os

def test_ctrl_c():
    """Test Ctrl+C signal handling"""
    print("\n=== Test 1: Ctrl+C (SIGINT) ===")
    print("This test will wait for you to press Ctrl+C.")
    print("Press Ctrl+C now...")

    received = [False]

    def handler(signum, frame):
        received[0] = True
        print("\n✅ SUCCESS: SIGINT (Ctrl+C) received!")

    old_handler = signal.signal(signal.SIGINT, handler)

    try:
        # Wait for up to 10 seconds for Ctrl+C
        import time
        for i in range(10):
            if received[0]:
                break
            time.sleep(1)
            if not received[0]:
                print(f"   Waiting... ({10-i-1}s remaining)")

        if not received[0]:
            print("\n❌ FAILED: No SIGINT received within 10 seconds")
            print("   Ctrl+C may not be working correctly.")
            return False
        return True
    finally:
        signal.signal(signal.SIGINT, old_handler)

def test_ctrl_d():
    """Test Ctrl+D (EOF) handling"""
    print("\n=== Test 2: Ctrl+D (EOF) ===")
    print("This test will read from stdin.")
    print("Press Ctrl+D (on empty line) to send EOF...")
    print("Type something and press Enter, then Ctrl+D on empty line:")

    try:
        lines = []
        while True:
            try:
                line = input("> ")
                lines.append(line)
            except EOFError:
                print("\n✅ SUCCESS: EOF (Ctrl+D) received!")
                print(f"   Lines entered before EOF: {len(lines)}")
                return True
    except KeyboardInterrupt:
        print("\n⚠️  Got Ctrl+C instead of Ctrl+D")
        return False

def main():
    print("=" * 50)
    print("cmux Control Signal Test")
    print("=" * 50)
    print("\nThis script tests if Ctrl+C and Ctrl+D work correctly.")
    print("Run this inside the cmux terminal to verify the fix.\n")

    # This script expects a human driving an interactive TTY. In automated
    # runners, skip instead of producing false negatives.
    if not os.isatty(sys.stdin.fileno()) or not os.isatty(sys.stdout.fileno()):
        print("SKIP: interactive test requires a TTY")
        return 0

    results = []

    # Test Ctrl+C
    try:
        results.append(("Ctrl+C (SIGINT)", test_ctrl_c()))
    except Exception as e:
        print(f"Error in Ctrl+C test: {e}")
        results.append(("Ctrl+C (SIGINT)", False))

    # Test Ctrl+D
    try:
        results.append(("Ctrl+D (EOF)", test_ctrl_d()))
    except Exception as e:
        print(f"Error in Ctrl+D test: {e}")
        results.append(("Ctrl+D (EOF)", False))

    # Summary
    print("\n" + "=" * 50)
    print("Test Results Summary")
    print("=" * 50)

    all_passed = True
    for name, passed in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"  {name}: {status}")
        if not passed:
            all_passed = False

    print()
    if all_passed:
        print("All tests passed! Control signals are working correctly.")
    else:
        print("Some tests failed. Check the key input handling code.")

    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())
