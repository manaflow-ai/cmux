#!/bin/bash
# Terminal rendering test: prints dimensions, a colored box, and a grid
# to verify spacing, font metrics, and color rendering on iOS.

# Colors
RED='\033[41m'    # Red background
GRN='\033[42m'    # Green background
BLU='\033[44m'    # Blue background
YEL='\033[43m'    # Yellow background
RST='\033[0m'     # Reset
BOLD='\033[1m'
RED_FG='\033[31m'
GRN_FG='\033[32m'
BLU_FG='\033[34m'
YEL_FG='\033[33m'
CYN_FG='\033[36m'
MAG_FG='\033[35m'

# Get terminal size
COLS=$(tput cols 2>/dev/null || echo "?")
ROWS=$(tput lines 2>/dev/null || echo "?")

echo -e "${BOLD}Terminal: ${COLS}x${ROWS}${RST}"
echo ""

# Draw a red box (10x5)
BOX_W=20
BOX_H=5
echo -e "${BOLD}Red box (${BOX_W}x${BOX_H}):${RST}"
for r in $(seq 1 $BOX_H); do
    printf "${RED}"
    printf "%${BOX_W}s" ""
    printf "${RST}\n"
done
echo ""

# Draw a color stripe
echo -e "${BOLD}Color stripe:${RST}"
printf "${RED}  RED  ${GRN}  GRN  ${BLU}  BLU  ${YEL}  YEL  ${RST}\n"
echo ""

# Character alignment grid
echo -e "${BOLD}Alignment grid:${RST}"
echo "0123456789012345678901234567890123456789"
echo "|    |    |    |    |    |    |    |    |"
echo "0         1         2         3        "
echo ""

# Unicode test
echo -e "${BOLD}Unicode:${RST}"
echo "ASCII:  Hello World"
echo "CJK:    你好世界"
echo "Emoji:  🔴🟢🔵🟡"
echo "Box:    ┌──────┐"
echo "        │ test │"
echo "        └──────┘"
echo ""

# Colored text
echo -e "${RED_FG}Red${RST} ${GRN_FG}Green${RST} ${BLU_FG}Blue${RST} ${YEL_FG}Yellow${RST} ${CYN_FG}Cyan${RST} ${MAG_FG}Magenta${RST}"
