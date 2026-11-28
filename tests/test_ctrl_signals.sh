#!/bin/bash
# Test script to verify Ctrl+C and Ctrl+D work correctly in the terminal
# Run this script inside the cmux terminal to test signal handling

set -e

echo "=== Control Signal Test Suite ==="
echo ""

# Test 1: Ctrl+C interrupt test
echo "Test 1: Ctrl+C (SIGINT) - Press Ctrl+C to interrupt the sleep"
echo "   A long sleep will start. Press Ctrl+C to interrupt it."
echo "   If Ctrl+C works, you should see 'SIGINT received!' within 2 seconds."
echo ""
echo "Starting sleep... (press Ctrl+C now)"

trap 'echo "SIGINT received! Ctrl+C is working correctly."; exit 0' INT

# Start a long sleep - user should interrupt this with Ctrl+C
sleep 30

# If we get here, Ctrl+C didn't work
echo "ERROR: Sleep completed without interruption. Ctrl+C may not be working!"
exit 1
