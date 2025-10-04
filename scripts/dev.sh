#!/bin/bash

set -e

export CONVEX_PORT=9777

if [ -f .env ]; then
    echo "Loading .env file"
    # Support quoted/multiline values (e.g., PEM keys) safely
    # by sourcing the file with export-all mode.
    set -a
    # shellcheck disable=SC1091
    . .env
    set +a
    echo "Loaded .env file"
fi

# Detect if we're running inside a devcontainer
IS_DEVCONTAINER=false
if [ -n "$REMOTE_CONTAINERS" ] || [ -n "$CODESPACES" ]; then
    IS_DEVCONTAINER=true
    # Set workspace directory for devcontainer - use current working directory's parent
    # Get the directory where this script is located
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    APP_DIR="$(dirname "$SCRIPT_DIR")"
else
    # Get the directory where this script is located
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    APP_DIR="$(dirname "$SCRIPT_DIR")"
fi

echo "IS_DEVCONTAINER: $IS_DEVCONTAINER"

# Parse command line arguments
FORCE_DOCKER_BUILD=false
SHOW_COMPOSE_LOGS=false
# Default to skipping Convex unless explicitly disabled via env/flag
SKIP_CONVEX="${SKIP_CONVEX:-true}"
RUN_ELECTRON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-docker-build)
            FORCE_DOCKER_BUILD=true
            shift
            ;;
        --show-compose-logs)
            SHOW_COMPOSE_LOGS=true
            shift
            ;;
        --electron)
            RUN_ELECTRON=true
            shift
            ;;
        --skip-convex)
            # Support `--skip-convex true|false` and bare `--skip-convex` (defaults to true)
            if [[ -n "${2:-}" && "${2}" != --* ]]; then
                case "$2" in
                    true|false)
                        SKIP_CONVEX="$2"
                        shift 2
                        ;;
                    *)
                        echo "Invalid value for --skip-convex: $2. Use true or false." >&2
                        exit 1
                        ;;
                esac
            else
                SKIP_CONVEX=true
                shift
            fi
            ;;
        --skip-convex=*)
            val="${1#*=}"
            if [[ "$val" = "true" || "$val" = "false" ]]; then
                SKIP_CONVEX="$val"
            else
                echo "Invalid value for --skip-convex: $val. Use true or false." >&2
                exit 1
            fi
            shift
            ;;
        *)
            # Unknown flag; ignore and shift
            shift
            ;;
    esac
done

# Only clean ports when not in devcontainer (devcontainer handles this)
if [ "$IS_DEVCONTAINER" = "false" ]; then
    # Check if anything is running on ports 5173, $CONVEX_PORT, 9777, 9778, 9779
    PORTS_TO_CHECK="5173 9779"
    # Use shared port cleanup helper
    source "$(dirname "$0")/_port-clean.sh"
    clean_ports $PORTS_TO_CHECK
fi

# Build Docker image (different logic for devcontainer vs host)
# Allow overriding the build platform for cross-architecture builds
DOCKER_BUILD_ARGS=(-t cmux-worker:0.0.1)
if [ -n "${CMUX_DOCKER_PLATFORM:-}" ]; then
    DOCKER_BUILD_ARGS+=(--platform "${CMUX_DOCKER_PLATFORM}")
fi

if [ "$IS_DEVCONTAINER" = "true" ]; then
    # In devcontainer, always build since we have access to docker socket
    echo "Building Docker image..."
    docker build "${DOCKER_BUILD_ARGS[@]}" "$APP_DIR" || exit 1
else
    # On host, build by default unless explicitly skipped
    if [ "$SKIP_DOCKER_BUILD" != "true" ] || [ "$FORCE_DOCKER_BUILD" = "true" ]; then
        echo "Building Docker image..."
        docker build "${DOCKER_BUILD_ARGS[@]}" . || exit 1
    else
        echo "Skipping Docker build (SKIP_DOCKER_BUILD=true)"
    fi
fi

# APP_DIR is already set above based on environment"

# Colors for output - export them for subshells
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export MAGENTA='\033[0;35m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

echo -e "${BLUE}Starting Terminal App Development Environment...${NC}"

# Change to app directory
cd "$APP_DIR"

# Function to cleanup on exit
cleanup() {
    echo -e "\n${BLUE}Shutting down...${NC}"
    # Kill the bash processes which will trigger their EXIT traps to kill all children
    [ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null
    [ -n "$CLIENT_PID" ] && kill $CLIENT_PID 2>/dev/null
    [ -n "$WWW_PID" ] && kill $WWW_PID 2>/dev/null
    [ -n "$CONVEX_DEV_PID" ] && kill $CONVEX_DEV_PID 2>/dev/null
    [ -n "$DOCKER_COMPOSE_PID" ] && kill $DOCKER_COMPOSE_PID 2>/dev/null
    [ -n "$SERVER_GLOBAL_PID" ] && kill $SERVER_GLOBAL_PID 2>/dev/null
    [ -n "$OPENAPI_CLIENT_PID" ] && kill $OPENAPI_CLIENT_PID 2>/dev/null
    [ -n "$ELECTRON_PID" ] && kill $ELECTRON_PID 2>/dev/null
    # Give processes time to cleanup
    sleep 1
    # Force kill any remaining processes
    [ -n "$SERVER_PID" ] && kill -9 $SERVER_PID 2>/dev/null
    [ -n "$CLIENT_PID" ] && kill -9 $CLIENT_PID 2>/dev/null
    [ -n "$WWW_PID" ] && kill -9 $WWW_PID 2>/dev/null
    [ -n "$CONVEX_DEV_PID" ] && kill -9 $CONVEX_DEV_PID 2>/dev/null
    [ -n "$DOCKER_COMPOSE_PID" ] && kill -9 $DOCKER_COMPOSE_PID 2>/dev/null
    [ -n "$SERVER_GLOBAL_PID" ] && kill -9 $SERVER_GLOBAL_PID 2>/dev/null
    [ -n "$OPENAPI_CLIENT_PID" ] && kill -9 $OPENAPI_CLIENT_PID 2>/dev/null
    [ -n "$ELECTRON_PID" ] && kill -9 $ELECTRON_PID 2>/dev/null
    exit
}

# Set up trap to cleanup on script exit
trap cleanup EXIT INT TERM

# Check if node_modules exist, if not install dependencies
if [ ! -d "node_modules" ] || [ "$FORCE_INSTALL" = "true" ]; then
    echo -e "${BLUE}Installing dependencies...${NC}"
    CI=1 bun install --frozen-lockfile || exit 1
fi

# Build Rust N-API addon (required)
echo -e "${GREEN}Building native Rust addon...${NC}"
(cd "$APP_DIR/apps/server/native/core" && bunx --bun @napi-rs/cli build --platform)

# Function to prefix output with colored labels
prefix_output() {
    local label="$1"
    local color="$2"
    while IFS= read -r line; do
        echo -e "${color}[${label}]${NC} $line"
    done
}
# Export the function so it's available in subshells
export -f prefix_output

# Create logs directory if it doesn't exist
mkdir -p "$APP_DIR/logs"
# Export a shared log directory for subshells
export LOG_DIR="$APP_DIR/logs"
export SHOW_COMPOSE_LOGS

# Start convex dev and log to both stdout and file
echo -e "${GREEN}Starting convex dev...${NC}"
# (cd packages/convex && source ~/.nvm/nvm.sh && nvm use 18 && CONVEX_AGENT_MODE=anonymous bun x convex dev 2>&1 | tee ../../logs/convex.log) &
# (cd packages/convex && source ~/.nvm/nvm.sh && \
#   nvm use 18 && \
#   source .env.local && \
#   ./convex-local-backend \
#     --port "$CONVEX_PORT" \
#     --site-proxy-port "$CONVEX_SITE_PROXY_PORT" \
#     --instance-name "$CONVEX_INSTANCE_NAME" \
#     --instance-secret "$CONVEX_INSTANCE_SECRET" \
#     --disable-beacon \
#     2>&1 | tee ../../logs/convex.log | prefix_output "CONVEX-BACKEND" "$MAGENTA") &
# CONVEX_BACKEND_PID=$!

# Function to check if a background process started successfully
check_process() {
    local pid=$1
    local name=$2
    sleep 0.5  # Give the process a moment to start
    if ! kill -0 $pid 2>/dev/null; then
        echo -e "${RED}Failed to start $name${NC}"
        exit 1
    fi
}

# Start Convex backend (different for devcontainer vs host)
if [ "$SKIP_CONVEX" = "true" ]; then
    echo -e "${YELLOW}Skipping Convex (SKIP_CONVEX=true)${NC}"
else
    if [ "$IS_DEVCONTAINER" = "true" ]; then
        # In devcontainer, Convex is already running as part of docker-compose
        echo -e "${GREEN}Convex backend already running in devcontainer...${NC}"
    else
        # On host, start Convex via docker-compose
        (cd .devcontainer && exec bash -c 'trap "kill -9 0" EXIT; \
          COMPOSE_PROJECT_NAME=cmux-convex docker compose -f docker-compose.convex.yml up 2>&1 | tee "$LOG_DIR/docker-compose.log" | { \
            if [ "${SHOW_COMPOSE_LOGS}" = "true" ]; then \
              prefix_output "DOCKER-COMPOSE" "$MAGENTA"; \
            else \
              cat >/dev/null; \
            fi; \
          }') &
        DOCKER_COMPOSE_PID=$!
        check_process $DOCKER_COMPOSE_PID "Docker Compose"
    fi
fi

# We need to start convex dev even if we're skipping convex
# Start convex dev (works the same in both environments)
(cd "$APP_DIR/packages/convex" && exec bash -c 'trap "kill -9 0" EXIT; source ~/.nvm/nvm.sh 2>/dev/null || true; bunx convex dev 2>&1 | tee "$LOG_DIR/convex-dev.log" | prefix_output "CONVEX-DEV" "$BLUE"') &
CONVEX_DEV_PID=$!
check_process $CONVEX_DEV_PID "Convex Dev"
CONVEX_PID=$CONVEX_DEV_PID

# Start the backend server
echo -e "${GREEN}Starting backend server on port 9776...${NC}"
(cd "$APP_DIR/apps/server" && exec bash -c 'trap "kill -9 0" EXIT; bun run dev 2>&1 | tee "$LOG_DIR/server.log" | prefix_output "SERVER" "$YELLOW"') &
SERVER_PID=$!
check_process $SERVER_PID "Backend Server"

# Start the frontend
echo -e "${GREEN}Starting frontend on port 5173...${NC}"
(cd "$APP_DIR/apps/client" && exec bash -c 'trap "kill -9 0" EXIT; bun run dev --host 0.0.0.0 2>&1 | tee "$LOG_DIR/client.log" | prefix_output "CLIENT" "$CYAN"') &
CLIENT_PID=$!
check_process $CLIENT_PID "Frontend Client"

# Start the www app
echo -e "${GREEN}Starting www app on port 9779...${NC}"
(cd "$APP_DIR/apps/www" && exec bash -c 'trap "kill -9 0" EXIT; bun run dev 2>&1 | tee "$LOG_DIR/www.log" | prefix_output "WWW" "$GREEN"') &
WWW_PID=$!
check_process $WWW_PID "WWW App"

# Start the openapi client generator
echo -e "${GREEN}Starting openapi client generator...${NC}"
(cd "$APP_DIR/apps/www" && exec bash -c 'trap "kill -9 0" EXIT; bun run generate-openapi-client:watch 2>&1 | tee "$LOG_DIR/openapi-client.log" | prefix_output "OPENAPI-CLIENT" "$MAGENTA"') &
OPENAPI_CLIENT_PID=$!
check_process $OPENAPI_CLIENT_PID "OpenAPI Client Generator"

# Start Electron if requested
if [ "$RUN_ELECTRON" = "true" ]; then
    echo -e "${GREEN}Starting Electron app...${NC}"
    (cd "$APP_DIR/apps/client" && exec bash -c 'trap "kill -9 0" EXIT; bunx dotenv-cli -e ../../.env -- pnpm dev:electron 2>&1 | tee "$LOG_DIR/electron.log" | prefix_output "ELECTRON" "$RED"') &
    ELECTRON_PID=$!
    check_process $ELECTRON_PID "Electron App"
fi

echo -e "${GREEN}Terminal app is running!${NC}"
echo -e "${BLUE}Frontend: http://localhost:5173${NC}"
echo -e "${BLUE}Backend: http://localhost:9776${NC}"
echo -e "${BLUE}WWW: http://localhost:9779${NC}"
if [ "$SKIP_CONVEX" != "true" ]; then
    echo -e "${BLUE}Convex: http://localhost:$CONVEX_PORT${NC}"
fi
if [ "$RUN_ELECTRON" = "true" ]; then
    echo -e "${BLUE}Electron app is starting...${NC}"
fi
echo -e "\nPress Ctrl+C to stop all services"

# Wait for both processes
wait
