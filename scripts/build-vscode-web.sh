#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Building VSCode Web...${NC}"

# Change to vendor/openvscode-server directory
cd vendor/openvscode-server

# Source nvm and switch to correct Node version
echo -e "${BLUE}Setting up Node environment...${NC}"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Use Node version from .nvmrc
nvm use

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
    echo -e "${BLUE}Installing dependencies...${NC}"
    npm install
else
    echo -e "${GREEN}Dependencies already installed${NC}"
fi

# Build web version
echo -e "${BLUE}Building VSCode Web...${NC}"
npm run compile-web

# Create target directory in apps/client
TARGET_DIR="../../apps/client/public/vscode"
echo -e "${BLUE}Creating target directory: $TARGET_DIR${NC}"
mkdir -p $TARGET_DIR

# Copy the built files
echo -e "${BLUE}Copying built files to $TARGET_DIR...${NC}"

# Check for build output
if [ -d "out-build" ]; then
    echo -e "${BLUE}Copying out-build directory...${NC}"
    cp -r out-build/* $TARGET_DIR/
else
    echo -e "${RED}Error: no build output found${NC}"
    exit 1
fi

# Copy product.json if it exists
if [ -f "product.json" ]; then
    cp product.json $TARGET_DIR/
fi

# Copy extensions if they exist
if [ -d "extensions" ]; then
    echo -e "${BLUE}Copying extensions...${NC}"
    cp -r extensions $TARGET_DIR/
fi

echo -e "${GREEN}VSCode Web build complete!${NC}"
echo -e "${GREEN}Files copied to: apps/client/public/vscode${NC}"

# Create necessary symlinks for missing files
echo -e "${BLUE}Creating necessary symlinks...${NC}"
cd $TARGET_DIR
if [ -f "vs/workbench/browser/web.factory.js" ] && [ ! -f "vs/workbench/workbench.web.main.internal.js" ]; then
    ln -sf browser/web.factory.js vs/workbench/workbench.web.main.internal.js
fi
# Create stub for missing workspaces service if needed
if [ ! -f "vs/workbench/services/workspaces/browser/workspaces.js" ]; then
    mkdir -p vs/workbench/services/workspaces/browser
    echo "export const WorkspacesService = {}; export default {};" > vs/workbench/services/workspaces/browser/workspaces.js
fi

# List what was copied
echo -e "${BLUE}Contents of target directory:${NC}"
ls -la $TARGET_DIR | head -20