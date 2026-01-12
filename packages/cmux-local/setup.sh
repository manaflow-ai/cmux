#!/bin/bash
#
# CMUX Local - One-Command Setup
#
# Usage: ./setup.sh
#
# This script:
# 1. Checks Docker is running
# 2. Checks/prompts for ANTHROPIC_API_KEY
# 3. Builds the Docker image
# 4. Creates a shell alias
# 5. Shows you how to use it
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  CMUX Local Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 1. Check Docker
echo -e "${CYAN}[1/4]${NC} Checking Docker..."
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}  ✗ Docker is not running${NC}"
    echo -e "  Please start Docker Desktop and run this script again."
    exit 1
fi
echo -e "${GREEN}  ✓ Docker is running${NC}"

# 2. Check ANTHROPIC_API_KEY
echo ""
echo -e "${CYAN}[2/4]${NC} Checking ANTHROPIC_API_KEY..."
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo -e "${YELLOW}  ! ANTHROPIC_API_KEY is not set${NC}"
    echo ""
    read -p "  Enter your Anthropic API key (or press Enter to skip): " api_key
    if [ -n "$api_key" ]; then
        export ANTHROPIC_API_KEY="$api_key"
        echo ""
        echo -e "${YELLOW}  To make this permanent, add to your ~/.zshrc or ~/.bashrc:${NC}"
        echo -e "  export ANTHROPIC_API_KEY=$api_key"
    else
        echo -e "${YELLOW}  Skipping. You'll need to set this before running tasks.${NC}"
    fi
else
    echo -e "${GREEN}  ✓ ANTHROPIC_API_KEY is set${NC}"
fi

# 3. Build Docker image
echo ""
echo -e "${CYAN}[3/4]${NC} Building Docker image (this may take 2-3 minutes)..."

# Check if image already exists
if docker images -q cmux-local-worker 2>/dev/null | grep -q .; then
    echo -e "${GREEN}  ✓ Image already exists (use 'docker rmi cmux-local-worker' to rebuild)${NC}"
else
    docker build -t cmux-local-worker "$SCRIPT_DIR" 2>&1 | while read line; do
        echo "    $line"
    done
    echo -e "${GREEN}  ✓ Docker image built${NC}"
fi

# 4. Create alias
echo ""
echo -e "${CYAN}[4/4]${NC} Setting up shell alias..."

ALIAS_CMD="alias cmux-local='bun run ${SCRIPT_DIR}/src/index.ts'"
SHELL_RC=""

if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    if grep -q "alias cmux-local=" "$SHELL_RC" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Alias already exists in $SHELL_RC${NC}"
    else
        read -p "  Add alias to $SHELL_RC? [Y/n] " add_alias
        if [ "$add_alias" != "n" ] && [ "$add_alias" != "N" ]; then
            echo "" >> "$SHELL_RC"
            echo "# CMUX Local" >> "$SHELL_RC"
            echo "$ALIAS_CMD" >> "$SHELL_RC"
            echo -e "${GREEN}  ✓ Alias added to $SHELL_RC${NC}"
            echo -e "${YELLOW}  Run 'source $SHELL_RC' or open a new terminal to use it${NC}"
        fi
    fi
fi

# Done!
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Quick Start:${NC}"
echo ""
echo -e "  # Start a task in your project"
echo -e "  ${GREEN}cd ~/your-project${NC}"
echo -e "  ${GREEN}cmux-local \"Add dark mode toggle\"${NC}"
echo ""
echo -e "  # Monitor tasks and answer questions"
echo -e "  ${GREEN}cmux-local${NC}"
echo ""
echo -e "  # Or run directly without alias:"
echo -e "  ${GREEN}bun run ${SCRIPT_DIR}/src/index.ts \"Your task\"${NC}"
echo ""
echo -e "  ${CYAN}Other commands:${NC}"
echo -e "  cmux-local list       # List running tasks"
echo -e "  cmux-local stop-all   # Stop all tasks"
echo -e "  cmux-local --help     # Show all options"
echo ""
