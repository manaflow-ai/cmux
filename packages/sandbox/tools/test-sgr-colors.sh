#!/bin/bash
# Test SGR 24-bit colors (multiple colors visible at once)
# This tests the renderer's ability to show different colors per-line

echo "=== SGR 24-bit Color Test ==="
echo "Each line should have a DIFFERENT background color visible simultaneously:"
echo ""

# Background colors using SGR 48;2;R;G;B
echo -e "\033[48;2;102;0;0m  DARK RED BACKGROUND      \033[0m"
echo -e "\033[48;2;0;102;0m  DARK GREEN BACKGROUND    \033[0m"
echo -e "\033[48;2;0;0;102m  DARK BLUE BACKGROUND     \033[0m"
echo -e "\033[48;2;102;102;0m  DARK YELLOW BACKGROUND   \033[0m"
echo -e "\033[48;2;102;0;102m  DARK MAGENTA BACKGROUND  \033[0m"
echo -e "\033[48;2;0;102;102m  DARK CYAN BACKGROUND     \033[0m"

echo ""
echo "Foreground colors using SGR 38;2;R;G;B:"
echo ""

echo -e "\033[38;2;255;0;0m  RED TEXT\033[0m"
echo -e "\033[38;2;0;255;0m  GREEN TEXT\033[0m"
echo -e "\033[38;2;0;0;255m  BLUE TEXT\033[0m"
echo -e "\033[38;2;255;255;0m  YELLOW TEXT\033[0m"
echo -e "\033[38;2;255;0;255m  MAGENTA TEXT\033[0m"
echo -e "\033[38;2;0;255;255m  CYAN TEXT\033[0m"

echo ""
echo "Combined foreground + background:"
echo ""

echo -e "\033[38;2;255;255;255;48;2;102;0;0m  WHITE on RED    \033[0m"
echo -e "\033[38;2;0;0;0;48;2;0;255;0m  BLACK on GREEN  \033[0m"
echo -e "\033[38;2;255;255;0;48;2;0;0;102m  YELLOW on BLUE  \033[0m"

echo ""
echo "=== Test Complete ==="
echo "If you see 6 different colored backgrounds and 6 different colored texts above,"
echo "then SGR 24-bit color rendering is working correctly!"
