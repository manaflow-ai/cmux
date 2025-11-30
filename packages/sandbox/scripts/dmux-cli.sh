#!/usr/bin/env bash
set -euo pipefail

# dmux-cli.sh - CLI wrapper for the development/debug sandbox server
# Uses different ports/containers than cmux to avoid conflicts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-dmux-sandbox-dev-run}"
PORT="${DMUX_SANDBOX_PORT:-46833}"

# Helper function to start the server
start_server() {
  echo "Starting server container '${CONTAINER_NAME}'..."
  CMUX_NO_ATTACH=1 "${SCRIPT_DIR}/dmux.sh"
}

# Helper function to stop the server
stop_server() {
  echo "Stopping server container '${CONTAINER_NAME}'..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

# Handle 'server' meta-commands
if [[ "${1:-}" == "server" ]]; then
  shift
  case "${1:-}" in
    start)
      start_server
      ;;
    stop)
      stop_server
      ;;
    restart|rebuild)
      stop_server
      start_server
      ;;
    logs)
      docker logs -f "${CONTAINER_NAME}"
      ;;
    status)
      if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Server '${CONTAINER_NAME}' is RUNNING."
      else
        echo "Server '${CONTAINER_NAME}' is STOPPED."
      fi
      ;;
    *)
      echo "Usage: $0 server {start|stop|restart|logs|status}"
      exit 1
      ;;
  esac
  exit 0
fi

# Check if the server is running and healthy (fastest check)
if curl -s "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
  : # Server is up, do nothing
else
  # Server not responding, check if container exists
  if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
     echo "Container is running but server is not responding. Restarting..."
     start_server
  else
    echo "Server container '${CONTAINER_NAME}' is not running. Starting it..."
    start_server
  fi
fi

# Build and run the CLI locally, passing all arguments
# We use cargo run to ensure we're using the latest code in the dev environment.
# Using -q to keep it quiet unless there's an error.
cd "${ROOT_DIR}/packages/sandbox"
cargo run -q --bin dmux -- "$@"
