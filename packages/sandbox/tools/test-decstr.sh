#!/bin/bash
# Test script for CSI ! p (DECSTR - Soft Terminal Reset)
# Run this inside cmux/dmux to verify the implementation

echo "=== Testing CSI ! p (DECSTR - Soft Terminal Reset) ==="
echo ""

# Test 1: SGR reset
echo "Test 1: SGR (text attributes) reset"
echo -n "Before: "
printf '\033[1;31;44m'  # Bold, red on blue
echo -n "STYLED TEXT"
printf '\033[!p'        # Soft reset
echo -n " | After: "
echo "NORMAL TEXT"
echo "  -> 'STYLED TEXT' should be bold red on blue"
echo "  -> 'NORMAL TEXT' should be plain/default"
echo ""

# Test 2: Cursor visibility reset
echo "Test 2: Cursor visibility reset"
printf '\033[?25l'      # Hide cursor
echo "Cursor hidden..."
sleep 0.5
printf '\033[!p'        # Soft reset - should make cursor visible
echo "Soft reset done - cursor should now be VISIBLE"
echo ""

# Test 3: Verify screen content preserved
echo "Test 3: Screen content preservation"
echo "Line A - this should remain"
echo "Line B - this should remain"
echo "Line C - this should remain"
printf '\033[1;4;35m'   # Bold, underline, magenta
printf '\033[!p'        # Soft reset
echo "Line D - this should be unstyled, and lines A/B/C above should still exist"
echo ""

# Test 4: Insert mode reset
echo "Test 4: Insert mode reset"
printf '\033[4h'        # Enable insert mode
printf '\033[!p'        # Soft reset should disable it
echo "Insert mode should be OFF (default)"
echo ""

# Test 5: Auto-wrap should be ON after reset
echo "Test 5: Auto-wrap mode (should be ON after reset)"
printf '\033[?7l'       # Disable auto-wrap
printf '\033[!p'        # Soft reset should enable it
echo "Auto-wrap should be ON (default)"
echo ""

echo "=== DECSTR Test Complete ==="
echo ""
echo "Verification:"
echo "  1. Test 1: First part styled, second part plain"
echo "  2. Test 2: Cursor should be visible after reset"
echo "  3. Test 3: Lines A/B/C should still be visible above"
echo "  4. All text after 'Soft reset' should be in default style"
