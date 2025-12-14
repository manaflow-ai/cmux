#!/bin/bash

# Start development environment using devcontainer
# This allows running the devcontainer from command line without VS Code

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting cmux development environment in devcontainer...${NC}"

# Function to cleanup on exit
cleanup() {
    echo -e "\n${BLUE}Shutting down devcontainer...${NC}"
    docker compose -f .devcontainer/docker-compose.yml down
    exit
}

# Set up trap to cleanup on script exit
trap cleanup EXIT INT TERM

# Check if devcontainer CLI is available
if ! command -v bunx &> /dev/null; then
    echo -e "${RED}bunx is not installed. Please install bun first.${NC}"
    exit 1
fi

# Start the devcontainer
echo -e "${GREEN}Starting devcontainer services...${NC}"
bunx @devcontainers/cli up --workspace-folder . --remove-existing-container

# Get the container name
CONTAINER_NAME=$(docker compose -f .devcontainer/docker-compose.yml ps -q app)

if [ -z "$CONTAINER_NAME" ]; then
    echo -e "${RED}Failed to start devcontainer${NC}"
    exit 1
fi

echo -e "${GREEN}Devcontainer is running!${NC}"
echo -e "${BLUE}Frontend: http://localhost:9775${NC}"
echo -e "${BLUE}Backend: http://localhost:9776${NC}"
echo -e "${BLUE}Convex Backend: http://localhost:9777${NC}"
echo -e "${BLUE}Convex Dashboard: http://localhost:6791${NC}"
echo -e "\n${YELLOW}Attaching to devcontainer...${NC}"
echo -e "${YELLOW}Press Ctrl+D to exit the container shell${NC}\n"

# Exec into the container
docker exec -it $CONTAINER_NAME /bin/zsh