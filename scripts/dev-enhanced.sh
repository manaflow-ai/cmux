#!/bin/bash

# Enhanced dev script that can run either locally or in a devcontainer

set -e

# Parse command line arguments
USE_DEVCONTAINER=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --devcontainer|-d)
            USE_DEVCONTAINER=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--devcontainer|-d]"
            exit 1
            ;;
    esac
done

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

if [ "$USE_DEVCONTAINER" = true ]; then
    echo -e "${BLUE}Starting development environment in devcontainer...${NC}"
    
    # Use docker-compose directly for better control
    echo -e "${GREEN}Starting docker-compose services...${NC}"
    docker compose -f .devcontainer/docker-compose.yml up -d
    
    # Wait for services to be healthy
    echo -e "${YELLOW}Waiting for services to be ready...${NC}"
    docker compose -f .devcontainer/docker-compose.yml wait backend
    
    # Get container ID
    CONTAINER_ID=$(docker compose -f .devcontainer/docker-compose.yml ps -q app)
    
    if [ -z "$CONTAINER_ID" ]; then
        echo -e "${RED}Failed to start app container${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Services are running!${NC}"
    echo -e "${BLUE}Frontend: http://localhost:9775${NC}"
    echo -e "${BLUE}Backend: http://localhost:9776${NC}"
    echo -e "${BLUE}Convex Backend: http://localhost:9777${NC}"
    echo -e "${BLUE}Convex Dashboard: http://localhost:6791${NC}"
    
    # Run the dev script inside the container
    echo -e "\n${YELLOW}Starting development servers inside container...${NC}"
    docker exec -it "$CONTAINER_ID" bash -lc "cd /root/workspace && ./scripts/dev.sh"
else
    # Run the original dev.sh script
    echo -e "${BLUE}Starting development environment locally...${NC}"
    exec ./scripts/dev.sh
fi
