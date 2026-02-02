#!/bin/bash
#
# dev.sh - Start the cmux development environment
#
# Usage: ./scripts/dev.sh [options]
#
# Options:
#   --docker                Force build Docker image (alias for --force-docker-build)
#   --force-docker-build    Force rebuild the Docker image (overrides --skip-docker)
#   --skip-docker[=BOOL]    Skip Docker image build (default: true)
#   --skip-convex[=BOOL]    Skip Convex backend (default: true)
#   --show-compose-logs     Show Docker Compose logs in console
#   --electron              Start Electron app
#   --convex-agent          Run convex dev in agent mode
#
# Environment variables:
#   SKIP_DOCKER_BUILD       Set to "false" to build Docker image (default: true)
#   SKIP_CONVEX             Set to "false" to run Convex (default: true)
#
# Examples:
#   ./scripts/dev.sh                          # Start without Docker build
#   ./scripts/dev.sh --docker                 # Force Docker image rebuild
#   ./scripts/dev.sh --skip-docker=false      # Build Docker image
#   ./scripts/dev.sh --skip-convex=false      # Run with Convex enabled
#

set -e

hash_path() {
    local input=$1
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$input" | md5sum | awk '{print $1}' | cut -c1-8
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$input" | md5 | awk '{print $NF}' | cut -c1-8
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 | awk '{print $1}' | cut -c1-8
    else
        printf '%s' "nohash"
    fi
}

is_dev_script_pid() {
    local pid=$1
    if [ -z "$pid" ]; then
        return 1
    fi
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    case "$cmd" in
        *"scripts/dev.sh"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Prevent multiple dev.sh instances from running (per-project lockfile)
# Use a hash of APP_DIR to create a unique lockfile per project
SCRIPT_DIR_TMP="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR_TMP="$(dirname "$SCRIPT_DIR_TMP")"
PROJECT_HASH=$(hash_path "$APP_DIR_TMP")
LOCKFILE="/tmp/dev-server-${PROJECT_HASH}.lock"
LOCKDIR="/tmp/dev-server-${PROJECT_HASH}.lockdir"
PIDFILE="/tmp/dev-server-${PROJECT_HASH}.pid"
PATHFILE="/tmp/dev-server-${PROJECT_HASH}.path"
LOCK_METHOD="mkdir"

if command -v flock >/dev/null 2>&1; then
    LOCK_METHOD="flock"
fi

acquire_lock() {
    if [ "$LOCK_METHOD" = "flock" ]; then
        exec 200>"$LOCKFILE"
        flock -n 200 2>/dev/null || return 1
    else
        mkdir "$LOCKDIR" 2>/dev/null || return 1
    fi
}

release_lock() {
    if [ "$LOCK_METHOD" = "flock" ]; then
        flock -u 200 2>/dev/null || true
        rm -f "$LOCKFILE" 2>/dev/null || true
    fi
    rm -rf "$LOCKDIR" 2>/dev/null || true
}

if ! acquire_lock; then
    lock_failed=true
    existing_pid=""
    if [ -f "$PIDFILE" ]; then
        existing_pid=$(cat "$PIDFILE" 2>/dev/null || true)
    fi

    if [ "$LOCK_METHOD" = "mkdir" ]; then
        # Check for stale lock (process no longer running or not a dev.sh)
        if [ -z "$existing_pid" ] || ! is_dev_script_pid "$existing_pid"; then
            echo "Stale dev.sh lock detected. Cleaning up..."
            rm -rf "$LOCKDIR" 2>/dev/null || true
            rm -f "$PIDFILE" "$PATHFILE" 2>/dev/null || true
            if acquire_lock; then
                lock_failed=false
            fi
        fi
    fi

    # If lock still held by a running dev.sh, kill it and take over
    if [ "$lock_failed" = "true" ] && [ -n "$existing_pid" ] && is_dev_script_pid "$existing_pid"; then
        echo -e "\033[0;33mAnother dev.sh instance is running (PID: $existing_pid). Stopping it...\033[0m"

        # Kill process group and descendants
        kill -TERM -- "-$existing_pid" 2>/dev/null || true
        sleep 1
        kill -9 -- "-$existing_pid" 2>/dev/null || true

        # Clean up docker compose if path is known
        if [ -f "$PATHFILE" ]; then
            project_path=$(cat "$PATHFILE" 2>/dev/null || true)
            if [ -d "$project_path/.devcontainer" ]; then
                echo "Stopping docker compose..."
                for compose_file in "$project_path/.devcontainer"/docker-compose*.yml; do
                    [ -f "$compose_file" ] && docker compose -f "$compose_file" down 2>/dev/null || true
                done
            fi
        fi

        # Clean up lock files
        rm -rf "$LOCKDIR" 2>/dev/null || true
        rm -f "$LOCKFILE" "$PIDFILE" "$PATHFILE" 2>/dev/null || true

        # Retry acquiring lock
        sleep 1
        if acquire_lock; then
            lock_failed=false
            echo -e "\033[0;32mPrevious instance stopped. Starting new dev server...\033[0m"
        fi
    fi

    if [ "$lock_failed" = "true" ]; then
        echo -e "\033[0;31mFailed to acquire lock for dev.sh\033[0m"
        if [ -f "$PIDFILE" ]; then
            echo "PID: $(cat "$PIDFILE")"
        fi
        echo "Try running 'scripts/cleanup-dev.sh' manually."
        exit 1
    fi
fi

# Store our PID and project path for cleanup script
echo $$ > "$PIDFILE"
echo "$APP_DIR_TMP" > "$PATHFILE"

# Ensure the lock is released if we exit before the full cleanup trap is set.
trap 'release_lock; rm -f "$PIDFILE" "$PATHFILE" 2>/dev/null || true' EXIT

# Enable job control for process group management
set -m

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
SKIP_DOCKER_BUILD="${SKIP_DOCKER_BUILD:-true}"
CONVEX_AGENT_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)
            FORCE_DOCKER_BUILD=true
            shift
            ;;
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
        --skip-docker)
            # Support `--skip-docker true|false` and bare `--skip-docker` (defaults to true)
            if [[ -n "${2:-}" && "${2}" != --* ]]; then
                case "$2" in
                    true|false)
                        SKIP_DOCKER_BUILD="$2"
                        shift 2
                        ;;
                    *)
                        echo "Invalid value for --skip-docker: $2. Use true or false." >&2
                        exit 1
                        ;;
                esac
            else
                SKIP_DOCKER_BUILD=true
                shift
            fi
            ;;
        --skip-docker=*)
            val="${1#*=}"
            if [[ "$val" = "true" || "$val" = "false" ]]; then
                SKIP_DOCKER_BUILD="$val"
            else
                echo "Invalid value for --skip-docker: $val. Use true or false." >&2
                exit 1
            fi
            shift
            ;;
        --convex-agent)
            CONVEX_AGENT_MODE=true
            shift
            ;;
        *)
            # Unknown flag; ignore and shift
            shift
            ;;
    esac
done
export SKIP_DOCKER_BUILD

# Set the worker image name for local development
# This overrides the default (docker.io/lawrencecchen/cmux:latest) to use the locally-built image
export WORKER_IMAGE_NAME="cmux-worker:0.0.1"

# Only clean ports when not in devcontainer (devcontainer handles this)
if [ "$IS_DEVCONTAINER" = "false" ]; then
    # Check if anything is running on ports 5173, 9776, 9779
    PORTS_TO_CHECK="5173 9776 9779"
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

# Allow passing a GitHub token to avoid API rate limiting during docker builds.
# Prefer an existing GITHUB_TOKEN environment variable, otherwise fall back to `gh auth token`.
EFFECTIVE_GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [ -z "${EFFECTIVE_GITHUB_TOKEN}" ] && command -v gh >/dev/null 2>&1; then
    GH_AUTH_TOKEN="$(gh auth token 2>/dev/null || true)"
    # Guard against carriage returns when running on Windows hosts.
    GH_AUTH_TOKEN="${GH_AUTH_TOKEN//$'\r'/}"
    if [ -n "${GH_AUTH_TOKEN}" ]; then
        EFFECTIVE_GITHUB_TOKEN="${GH_AUTH_TOKEN}"
    fi
fi

if [ -n "${EFFECTIVE_GITHUB_TOKEN}" ]; then
    export GITHUB_TOKEN="${EFFECTIVE_GITHUB_TOKEN}"
    export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"
    DOCKER_BUILD_ARGS+=(--build-arg GITHUB_TOKEN --secret id=github_token,env=GITHUB_TOKEN)
fi

# Start Docker build (runs in background to parallelize with N-API build)
DOCKER_BUILD_PID=""
if [ "$IS_DEVCONTAINER" = "true" ]; then
    # In devcontainer, always build since we have access to docker socket
    echo "Building Docker image..."
    docker build "${DOCKER_BUILD_ARGS[@]}" "$APP_DIR" &
    DOCKER_BUILD_PID=$!
else
    # On host, build by default unless explicitly skipped
    if [ "$SKIP_DOCKER_BUILD" != "true" ] || [ "$FORCE_DOCKER_BUILD" = "true" ]; then
        echo "Building Docker image..."
        docker build "${DOCKER_BUILD_ARGS[@]}" . &
        DOCKER_BUILD_PID=$!
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

# Kill all descendant processes of a given PID (recursive)
kill_descendants() {
    local pid=$1
    local signal=${2:-TERM}
    local skip_pid=${3:-}
    if [ -z "$pid" ]; then
        return
    fi
    # Get all children of this process
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
        kill_descendants "$child" "$signal" "$skip_pid"
    done
    if [ -n "$skip_pid" ] && [ "$pid" -eq "$skip_pid" ]; then
        return
    fi
    kill -"$signal" "$pid" 2>/dev/null || true
}

kill_process_group() {
    local pid=$1
    local signal=${2:-TERM}
    if [ -z "$pid" ]; then
        return
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -"$signal" -- "-$pid" 2>/dev/null || true
    fi
}

# Function to cleanup on exit - kills entire process tree
cleanup() {
    if [ "${CLEANUP_STARTED:-false}" = "true" ]; then
        return
    fi
    CLEANUP_STARTED=true
    trap - EXIT INT TERM HUP QUIT

    echo -e "\n${BLUE}Shutting down...${NC}"

    for pid in "$DOCKER_BUILD_PID" "$DOCKER_COMPOSE_PID" "$CONVEX_DEV_PID" "$SERVER_PID" "$CLIENT_PID" "$WWW_PID" "$OPENAPI_CLIENT_PID" "$ELECTRON_PID" "$SERVER_GLOBAL_PID"; do
        kill_process_group "$pid" TERM
    done

    # Kill all descendants of this script (covers all spawned processes)
    # Skip killing this script to avoid re-entrant traps.
    kill_descendants $$ TERM "$$"

    # Give processes 2 seconds to cleanup gracefully
    sleep 2

    for pid in "$DOCKER_BUILD_PID" "$DOCKER_COMPOSE_PID" "$CONVEX_DEV_PID" "$SERVER_PID" "$CLIENT_PID" "$WWW_PID" "$OPENAPI_CLIENT_PID" "$ELECTRON_PID" "$SERVER_GLOBAL_PID"; do
        kill_process_group "$pid" 9
    done

    # Force kill any remaining descendants
    kill_descendants $$ 9 "$$"

    # Clean up any docker compose in this project's .devcontainer (if exists)
    if [ -d "$APP_DIR/.devcontainer" ]; then
        for compose_file in "$APP_DIR/.devcontainer"/docker-compose*.yml; do
            [ -f "$compose_file" ] && docker compose -f "$compose_file" down 2>/dev/null || true
        done
    fi

    # Release the lock and clean up temp files
    release_lock
    rm -f "$PIDFILE" "$PATHFILE" 2>/dev/null || true

    echo -e "${GREEN}Cleanup complete${NC}"
    exit
}

# Set up trap to cleanup on script exit
# Include HUP (terminal closed) and QUIT (Ctrl+\) for thorough coverage
trap cleanup EXIT INT TERM HUP QUIT

# Check if node_modules exist, if not install dependencies
if [ ! -d "node_modules" ] || [ "$FORCE_INSTALL" = "true" ]; then
    echo -e "${BLUE}Installing dependencies...${NC}"
    CI=1 bun install --frozen-lockfile || exit 1
fi

# Build Rust N-API addon (required) - runs in parallel with Docker build
echo -e "${GREEN}Building native Rust addon...${NC}"
(cd "$APP_DIR/apps/server/native/core" && bunx --bun @napi-rs/cli build --platform) || exit 1

# Wait for Docker build to complete if it was started
if [ -n "$DOCKER_BUILD_PID" ]; then
    echo -e "${BLUE}Waiting for Docker build to complete...${NC}"
    if ! wait $DOCKER_BUILD_PID; then
        echo -e "${RED}Docker build failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}Docker build completed${NC}"
fi

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

wait_for_log_message() {
    local log_file="$1"
    local marker="$2"
    local pid="$3"
    local name="$4"
    local timeout="${5:-120}"
    local waited=0

    echo -e "${BLUE}Waiting for ${name} to finish initial setup...${NC}"
    while true; do
        if [ -f "$log_file" ] && grep -Fq "$marker" "$log_file" 2>/dev/null; then
            echo -e "${GREEN}${name} initial setup completed${NC}"
            break
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}${name} exited before signaling readiness${NC}"
            exit 1
        fi

        if [ $waited -ge $timeout ]; then
            echo -e "${RED}Timed out waiting for ${name}${NC}"
            exit 1
        fi

        sleep 1
        waited=$((waited + 1))
    done
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
if [ "$CONVEX_AGENT_MODE" = "true" ]; then
    echo -e "${GREEN}Starting convex dev in agent mode...${NC}"
    (cd "$APP_DIR/packages/convex" && exec bash -c 'trap "kill -9 0" EXIT; source ~/.nvm/nvm.sh 2>/dev/null || true; CONVEX_DEPLOYMENT= CONVEX_AGENT_MODE=anonymous bunx convex dev 2>&1 | tee "$LOG_DIR/convex-dev.log" | prefix_output "CONVEX-DEV" "$BLUE"') &
else
    (cd "$APP_DIR/packages/convex" && exec bash -c 'trap "kill -9 0" EXIT; source ~/.nvm/nvm.sh 2>/dev/null || true; bunx convex dev 2>&1 | tee "$LOG_DIR/convex-dev.log" | prefix_output "CONVEX-DEV" "$BLUE"') &
fi
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

# Warm up www server in background (non-blocking)
(bash -c '
  for i in {1..30}; do
    if curl -s -f http://localhost:9779/api/health > /dev/null 2>&1; then
      echo -e "'"${GREEN}"'WWW server ready and warmed up'"${NC}"'"
      break
    fi
    sleep 0.5
  done
') &

# Warm up frontend in background (non-blocking)
(bash -c '
  for i in {1..30}; do
    if curl -s -f http://localhost:5173 > /dev/null 2>&1; then
      echo -e "'"${GREEN}"'Frontend ready and warmed up'"${NC}"'"
      break
    fi
    sleep 0.5
  done
') &

# Start the openapi client generator
echo -e "${GREEN}Starting openapi client generator...${NC}"
(cd "$APP_DIR/apps/www" && exec bash -c 'trap "kill -9 0" EXIT; bun run generate-openapi-client:watch 2>&1 | tee "$LOG_DIR/openapi-client.log" | prefix_output "OPENAPI-CLIENT" "$MAGENTA"') &
OPENAPI_CLIENT_PID=$!
check_process $OPENAPI_CLIENT_PID "OpenAPI Client Generator"
OPENAPI_LOG_FILE="$LOG_DIR/openapi-client.log"
OPENAPI_READY_MARKER="watch-openapi complete"
wait_for_log_message "$OPENAPI_LOG_FILE" "$OPENAPI_READY_MARKER" "$OPENAPI_CLIENT_PID" "OpenAPI Client Generator"

# Start Electron if requested
if [ "$RUN_ELECTRON" = "true" ]; then
    echo -e "${GREEN}Starting Electron app...${NC}"
    (cd "$APP_DIR/apps/client" && exec bash -c 'trap "kill -9 0" EXIT; bun run dev:electron 2>&1 | tee "$LOG_DIR/electron.log" | prefix_output "ELECTRON" "$RED"') &
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
