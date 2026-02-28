#!/usr/bin/env bash
# Populate cmux with many workspaces and splits for Cmd+P performance testing.
# Usage: ./scripts/populate-debug-workspaces.sh [socket-path]
#
# If no socket is given, defaults to /tmp/cmux-debug.sock (debug builds).
# For tagged builds: ./scripts/populate-debug-workspaces.sh /tmp/cmux-debug-cmdp-perf.sock

set -euo pipefail

SOCKET="${1:-/tmp/cmux-debug.sock}"
CMUX="cmux"

cmd() {
  "$CMUX" --socket "$SOCKET" "$@" 2>/dev/null
}

echo "Using socket: $SOCKET"
echo "Creating workspaces and splits..."

# Workspace names with varied themes for realistic search testing
WORKSPACE_NAMES=(
  "API Gateway"
  "Auth Service"
  "Payment Processing"
  "User Dashboard"
  "Database Migrations"
  "CI/CD Pipeline"
  "Monitoring & Alerts"
  "Feature Flags"
  "Email Templates"
  "Search Indexer"
  "WebSocket Server"
  "Cache Layer"
  "Rate Limiter"
  "File Upload Service"
  "Notification System"
  "Analytics Engine"
  "GraphQL Schema"
  "Docker Compose"
  "Kubernetes Configs"
  "Load Balancer"
)

# Directories to cd into for varied CWD metadata
DIRS=(
  "$HOME"
  "/tmp"
  "$HOME/fun"
  "$HOME/.config"
  "/usr/local"
  "$HOME/Downloads"
  "$HOME/Documents"
  "/var/log"
  "$HOME/.ssh"
  "/etc"
)

created=0

for name in "${WORKSPACE_NAMES[@]}"; do
  WS_ID=$(cmd new-workspace 2>/dev/null | sed 's/^OK //')
  if [ -z "$WS_ID" ]; then
    echo "  [skip] Failed to create workspace '$name'"
    continue
  fi
  sleep 0.3

  # Rename
  cmd rename-workspace "$WS_ID" "$name" || true
  sleep 0.2

  # Get the default surface
  SURFACES=$(cmd list-panes --workspace "$WS_ID" 2>/dev/null || true)

  # cd into a varied directory in the first surface
  DIR_IDX=$((created % ${#DIRS[@]}))
  DIR="${DIRS[$DIR_IDX]}"
  cmd send --workspace "$WS_ID" "cd $DIR && pwd"
  sleep 0.1
  cmd send-key --workspace "$WS_ID" enter
  sleep 0.3

  # Add a split for every 2nd workspace
  if (( created % 2 == 0 )); then
    cmd split --workspace "$WS_ID" --direction right 2>/dev/null || true
    sleep 0.3
  fi

  # Add a 3rd split for every 4th workspace
  if (( created % 4 == 0 )); then
    cmd split --workspace "$WS_ID" --direction down 2>/dev/null || true
    sleep 0.3
  fi

  created=$((created + 1))
  echo "  [$created/${#WORKSPACE_NAMES[@]}] Created: $name"
done

echo ""
echo "Done! Created $created workspaces."
echo "Open Cmd+P to test search performance."
