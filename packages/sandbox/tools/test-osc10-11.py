#!/usr/bin/env python3
"""Test script for OSC 10/11 (Query/Set Default Colors).

This script properly captures and validates terminal responses.
Run inside cmux/dmux to verify the implementation.
"""

import sys
import os
import termios
import tty
import select
import re

def read_response(timeout=0.5):
    """Read terminal response with timeout."""
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        response = b""
        while True:
            if select.select([fd], [], [], timeout)[0]:
                char = os.read(fd, 1)
                response += char
                # Check for ST (String Terminator) - ESC \ or BEL
                if response.endswith(b'\x1b\\') or response.endswith(b'\x07'):
                    break
            else:
                break
        return response.decode('utf-8', errors='replace')
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

def send_query(osc_num):
    """Send OSC query and get response."""
    # Send query
    sys.stdout.write(f'\x1b]{osc_num};?\x1b\\')
    sys.stdout.flush()

    # Read response
    response = read_response()
    return response

def parse_osc_response(response):
    """Parse OSC response and extract RGB values."""
    # Match OSC response format: ESC ] <num> ; rgb:RRRR/GGGG/BBBB ST
    match = re.search(r'\x1b\](\d+);rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+)', response)
    if match:
        osc_num = match.group(1)
        r = int(match.group(2), 16)
        g = int(match.group(3), 16)
        b = int(match.group(4), 16)
        return osc_num, r, g, b
    return None

def set_color(osc_num, color):
    """Set color via OSC sequence."""
    sys.stdout.write(f'\x1b]{osc_num};{color}\x1b\\')
    sys.stdout.flush()

def reset_color(osc_num):
    """Reset color to terminal default via OSC 110/111."""
    # OSC 110 = reset foreground, OSC 111 = reset background
    reset_osc = 110 if osc_num == 10 else 111
    sys.stdout.write(f'\x1b]{reset_osc}\x1b\\')
    sys.stdout.flush()

def print_result(test_name, expected, actual, passed):
    """Print test result with color."""
    status = "\x1b[32mPASS\x1b[0m" if passed else "\x1b[31mFAIL\x1b[0m"
    print(f"  {test_name}: {status}")
    if not passed:
        print(f"    Expected: {expected}")
        print(f"    Actual:   {actual}")

def main():
    print("=== OSC 10/11 (Default Colors) Test ===")
    print()

    all_passed = True

    # Test 1: Query default foreground (should be white = ffff/ffff/ffff)
    print("Test 1: Query default foreground color (OSC 10)")
    response = send_query(10)
    parsed = parse_osc_response(response)
    if parsed:
        osc, r, g, b = parsed
        # Default white is 255 * 257 = 65535 = 0xffff for each channel
        passed = (r == 0xffff and g == 0xffff and b == 0xffff)
        print_result("Default fg is white", "rgb:ffff/ffff/ffff", f"rgb:{r:04x}/{g:04x}/{b:04x}", passed)
        all_passed = all_passed and passed
    else:
        print_result("Default fg query", "valid response", repr(response), False)
        all_passed = False
    print()

    # Test 2: Query default background (should be black = 0000/0000/0000)
    print("Test 2: Query default background color (OSC 11)")
    response = send_query(11)
    parsed = parse_osc_response(response)
    if parsed:
        osc, r, g, b = parsed
        passed = (r == 0x0000 and g == 0x0000 and b == 0x0000)
        print_result("Default bg is black", "rgb:0000/0000/0000", f"rgb:{r:04x}/{g:04x}/{b:04x}", passed)
        all_passed = all_passed and passed
    else:
        print_result("Default bg query", "valid response", repr(response), False)
        all_passed = False
    print()

    # Test 3: Set foreground to red and verify
    print("Test 3: Set foreground to red (#ff0000)")
    set_color(10, "#ff0000")
    response = send_query(10)
    parsed = parse_osc_response(response)
    if parsed:
        osc, r, g, b = parsed
        # Red: 255 * 257 = 65535 = 0xffff, others = 0
        passed = (r == 0xffff and g == 0x0000 and b == 0x0000)
        print_result("Fg set to red", "rgb:ffff/0000/0000", f"rgb:{r:04x}/{g:04x}/{b:04x}", passed)
        all_passed = all_passed and passed
    else:
        print_result("Set fg to red", "valid response", repr(response), False)
        all_passed = False
    print()

    # Test 4: Set background to blue and verify
    print("Test 4: Set background to blue (#0000ff)")
    set_color(11, "#0000ff")
    response = send_query(11)
    parsed = parse_osc_response(response)
    if parsed:
        osc, r, g, b = parsed
        passed = (r == 0x0000 and g == 0x0000 and b == 0xffff)
        print_result("Bg set to blue", "rgb:0000/0000/ffff", f"rgb:{r:04x}/{g:04x}/{b:04x}", passed)
        all_passed = all_passed and passed
    else:
        print_result("Set bg to blue", "valid response", repr(response), False)
        all_passed = False
    print()

    # Test 5: Set using rgb: format
    print("Test 5: Set foreground using rgb: format (rgb:00/ff/00)")
    set_color(10, "rgb:00/ff/00")
    response = send_query(10)
    parsed = parse_osc_response(response)
    if parsed:
        osc, r, g, b = parsed
        # Green: 255 * 257 = 65535 = 0xffff
        passed = (r == 0x0000 and g == 0xffff and b == 0x0000)
        print_result("Fg set to green", "rgb:0000/ffff/0000", f"rgb:{r:04x}/{g:04x}/{b:04x}", passed)
        all_passed = all_passed and passed
    else:
        print_result("Set fg to green", "valid response", repr(response), False)
        all_passed = False
    print()

    # Reset to defaults
    print("Resetting colors to terminal defaults (OSC 110/111)...")
    reset_color(10)  # Reset foreground
    reset_color(11)  # Reset background
    print()

    # Summary
    print("=" * 40)
    if all_passed:
        print("\x1b[32mAll tests PASSED!\x1b[0m")
    else:
        print("\x1b[31mSome tests FAILED!\x1b[0m")
    print("=" * 40)
    print()

    # Visual demo
    print("=== Visual Demo ===")
    print("Watch the text color change as we modify OSC 10 (foreground):")
    print()

    import time

    colors = [
        ("#ff0000", "RED"),
        ("#00ff00", "GREEN"),
        ("#0000ff", "BLUE"),
        ("#ffff00", "YELLOW"),
        ("#ff00ff", "MAGENTA"),
        ("#00ffff", "CYAN"),
        ("#ffffff", "WHITE (default)"),
    ]

    for color, name in colors:
        set_color(10, color)
        # Print text without explicit color - it should use the default
        print(f"  This text should be {name}")
        sys.stdout.flush()
        time.sleep(0.5)

    print()
    print("Now changing background color (OSC 11):")
    print("Each line below will have a different background color:")
    reset_color(10)  # Reset fg to terminal default first
    print()

    bg_colors = [
        ("#660000", "DARK RED"),
        ("#006600", "DARK GREEN"),
        ("#000066", "DARK BLUE"),
        ("#666600", "DARK YELLOW"),
        ("#660066", "DARK MAGENTA"),
        ("#006666", "DARK CYAN"),
    ]

    # Print multiple lines for each color so the background is clearly visible
    for color, name in bg_colors:
        set_color(11, color)
        # Print several lines to make the background more visible
        print(f"  ========== {name} BACKGROUND ==========")
        print(f"  This line has {name} background")
        print(f"  Multiple lines to show the effect clearly")
        print()
        sys.stdout.flush()
        time.sleep(0.3)

    # Reset to terminal defaults
    reset_color(10)
    reset_color(11)
    print()
    print("Demo complete! Colors reset to terminal defaults (OSC 110/111).")

    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())
