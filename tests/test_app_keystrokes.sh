#!/bin/bash
# Test script that sends keystrokes to cmux via AppleScript
# This tests the actual keyboard input path through the app

set -e

echo "=== cmux Keystroke Test ==="
echo ""

# This script requires UI automation and manual verification. Keep it opt-in
# so automated suites don't fail on non-interactive environments.
if [[ "${CMUX_RUN_INTERACTIVE_TESTS:-0}" != "1" ]]; then
    echo "SKIP: manual UI keystroke test (set CMUX_RUN_INTERACTIVE_TESTS=1 to run)"
    exit 0
fi

APP_NAME="${CMUX_APP_NAME:-}"
if [[ -z "$APP_NAME" ]]; then
    APP_NAME="$(osascript -e 'tell application "System Events" to name of first process whose background only is false and name starts with "cmux"' 2>/dev/null || true)"
fi

if [[ -z "$APP_NAME" ]]; then
    echo "Error: no running cmux app process found"
    echo "Tip: launch cmux first or set CMUX_APP_NAME"
    exit 1
fi

echo "Using app: $APP_NAME"

# Activate cmux
osascript -e "tell application \"$APP_NAME\" to activate"
sleep 0.5

echo "Test 1: Testing Ctrl+C (SIGINT)"
echo "  Typing 'sleep 30' and pressing Enter..."

# Type the command
osascript -e 'tell application "System Events" to keystroke "sleep 30"'
sleep 0.2
osascript -e 'tell application "System Events" to keystroke return'
sleep 0.5

echo "  Sending Ctrl+C..."
# Send Ctrl+C
osascript -e 'tell application "System Events" to keystroke "c" using control down'
sleep 0.5

echo "  If you see '^C' or the command was interrupted, Ctrl+C is working!"
echo ""

echo "Test 2: Testing Ctrl+D (EOF)"
echo "  Starting cat command..."

# Type cat command
osascript -e 'tell application "System Events" to keystroke "cat"'
sleep 0.2
osascript -e 'tell application "System Events" to keystroke return'
sleep 0.5

echo "  Sending Ctrl+D..."
# Send Ctrl+D
osascript -e 'tell application "System Events" to keystroke "d" using control down'
sleep 0.5

echo "  If cat exited, Ctrl+D is working!"
echo ""

echo "=== Manual Verification Required ==="
echo "Please check the cmux window to verify:"
echo "  1. The 'sleep 30' command was interrupted by Ctrl+C"
echo "  2. The 'cat' command exited after Ctrl+D"
echo ""
echo "If both worked, the fix is successful!"
