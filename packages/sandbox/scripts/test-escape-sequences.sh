#!/bin/bash
# Test escape sequence support in the terminal emulator
# Run this script inside cmux/dmux to verify escape sequence support

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Terminal Escape Sequence Tester ==="
echo ""

# Function to test an escape sequence query and check the response
test_sequence() {
    local name="$1"
    local sequence="$2"
    local expected_pattern="$3"

    # Save terminal settings
    old_stty=$(stty -g)

    # Set terminal to raw mode with timeout
    stty raw -echo min 0 time 10

    # Send the sequence and read response
    printf "%b" "$sequence"
    response=$(dd bs=1 count=50 2>/dev/null | cat -v)

    # Restore terminal settings
    stty "$old_stty"

    echo -n "Testing $name: "

    if [[ "$response" =~ $expected_pattern ]]; then
        echo -e "${GREEN}PASS${NC}"
        echo "  Response: $response"
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected pattern: $expected_pattern"
        echo "  Got: $response"
        return 1
    fi
}

echo "--- Device Attributes Tests ---"
echo ""

# Test DA1 (Primary Device Attributes)
echo -n "Testing DA1 (CSI c): "
old_stty=$(stty -g)
stty raw -echo min 0 time 10
printf '\033[c'
response=$(dd bs=1 count=50 2>/dev/null | cat -v)
stty "$old_stty"
if [[ "$response" == *"[?62;1;2;4c"* ]]; then
    echo -e "${GREEN}PASS${NC}"
    echo "  Response: $response"
    echo "  Decoded: VT220 (62) with 132-col (1), printer (2), sixel (4)"
else
    echo -e "${RED}FAIL${NC}"
    echo "  Expected: ^[[?62;1;2;4c"
    echo "  Got: $response"
fi

echo ""

# Test DA2 (Secondary Device Attributes)
echo -n "Testing DA2 (CSI > c): "
old_stty=$(stty -g)
stty raw -echo min 0 time 10
printf '\033[>c'
response=$(dd bs=1 count=50 2>/dev/null | cat -v)
stty "$old_stty"
if [[ "$response" == *"[>41;0;0c"* ]]; then
    echo -e "${GREEN}PASS${NC}"
    echo "  Response: $response"
    echo "  Decoded: Screen-like terminal (41), version 0"
else
    echo -e "${RED}FAIL${NC}"
    echo "  Expected: ^[[>41;0;0c"
    echo "  Got: $response"
fi

echo ""

# Test DSR (Device Status Report)
echo -n "Testing DSR Status (CSI 5 n): "
old_stty=$(stty -g)
stty raw -echo min 0 time 10
printf '\033[5n'
response=$(dd bs=1 count=50 2>/dev/null | cat -v)
stty "$old_stty"
if [[ "$response" == *"[0n"* ]]; then
    echo -e "${GREEN}PASS${NC}"
    echo "  Response: $response"
    echo "  Decoded: Terminal OK"
else
    echo -e "${RED}FAIL${NC}"
    echo "  Expected: ^[[0n"
    echo "  Got: $response"
fi

echo ""

# Test CPR (Cursor Position Report)
echo -n "Testing CPR (CSI 6 n): "
old_stty=$(stty -g)
stty raw -echo min 0 time 10
printf '\033[6n'
response=$(dd bs=1 count=50 2>/dev/null | cat -v)
stty "$old_stty"
if [[ "$response" =~ \[([0-9]+)\;([0-9]+)R ]]; then
    echo -e "${GREEN}PASS${NC}"
    echo "  Response: $response"
    echo "  Decoded: Cursor at row ${BASH_REMATCH[1]}, col ${BASH_REMATCH[2]}"
else
    echo -e "${RED}FAIL${NC}"
    echo "  Expected: ^[[<row>;<col>R"
    echo "  Got: $response"
fi

echo ""
echo "--- Mode Tests ---"
echo ""

# Test Cursor Blink Mode
echo "Testing Cursor Blink Mode (CSI ? 12 h/l):"
echo "  Disabling cursor blink..."
printf '\033[?12l'
echo -e "  ${YELLOW}Cursor should now be STEADY (not blinking)${NC}"
echo "  Press Enter to continue..."
read -r

echo "  Enabling cursor blink..."
printf '\033[?12h'
echo -e "  ${YELLOW}Cursor should now be BLINKING${NC}"
echo "  Press Enter to continue..."
read -r

echo -e "  ${GREEN}Cursor blink mode test complete${NC}"
echo ""

echo "=== Tests Complete ==="
