#!/bin/bash
# Test script that sends keystrokes to cmux via AppleScript
# This tests the actual keyboard input path through the app

set -e

echo "=== cmux Keystroke Test ==="
echo ""

# Check if cmux is running
if ! pgrep -x "cmux" > /dev/null; then
    echo "Error: cmux is not running"
    echo "Please start cmux first"
    exit 1
fi

echo "cmux is running"
echo ""

# wait_for SECONDS WHAT CMD...: until CMD succeeds, or fail naming WHAT.
wait_for() {
    local seconds="$1" what="$2"
    shift 2
    for _ in $(seq 1 "$((seconds * 10))"); do
        "$@" && return 0
        sleep 0.1
    done
    "$@" && return 0
    echo "Error: $what" >&2
    exit 1
}

cmux_frontmost() {
    [[ "$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true')" == "cmux" ]]
}

# new_pid COMMAND_LINE: a pid running exactly COMMAND_LINE that was not running before ($before).
new_pid() {
    local pid
    for pid in $(pgrep -fx "$1" || true); do
        [[ " $before " == *" $pid "* ]] || { echo "$pid"; return 0; }
    done
    return 1
}

started() { pid="$(new_pid "$1")"; }
gone() { ! ps -p "$pid" >/dev/null 2>&1; }

# Activate cmux
osascript -e 'tell application "cmux" to activate'
wait_for 10 "cmux never became the frontmost app" cmux_frontmost

echo "Test 1: Testing Ctrl+C (SIGINT)"
echo "  Typing 'sleep 30' and pressing Enter..."

# Type the command (System Events posts keystrokes in order, so return follows the text)
before="$(pgrep -fx 'sleep 30' | tr '\n' ' ' || true)"
osascript -e 'tell application "System Events" to keystroke "sleep 30"'
osascript -e 'tell application "System Events" to keystroke return'
wait_for 10 "the typed 'sleep 30' never started in cmux" started 'sleep 30'

echo "  Sending Ctrl+C..."
# Send Ctrl+C
osascript -e 'tell application "System Events" to keystroke "c" using control down'
wait_for 10 "Ctrl+C did not interrupt 'sleep 30' (pid $pid)" gone

echo "  'sleep 30' was interrupted: Ctrl+C is working!"
echo ""

echo "Test 2: Testing Ctrl+D (EOF)"
echo "  Starting cat command..."

# Type cat command
before="$(pgrep -fx 'cat' | tr '\n' ' ' || true)"
osascript -e 'tell application "System Events" to keystroke "cat"'
osascript -e 'tell application "System Events" to keystroke return'
wait_for 10 "the typed 'cat' never started in cmux" started 'cat'

echo "  Sending Ctrl+D..."
# Send Ctrl+D
osascript -e 'tell application "System Events" to keystroke "d" using control down'
wait_for 10 "Ctrl+D did not end 'cat' (pid $pid)" gone

echo "  cat exited: Ctrl+D is working!"
echo ""

echo "=== Manual Verification Required ==="
echo "Please check the cmux window to verify:"
echo "  1. The 'sleep 30' command was interrupted by Ctrl+C"
echo "  2. The 'cat' command exited after Ctrl+D"
echo ""
echo "If both worked, the fix is successful!"
