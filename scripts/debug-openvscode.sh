#!/usr/bin/env bash
set -euo pipefail

# Quick launcher for a single OpenVSCode container that copies your local VS Code settings.
#
# Usage:
#   scripts/debug-openvscode.sh [-w <workspace-dir>] [-i <image>] [--rebuild] [--insiders]
#
# -w: Host workspace directory to mount at /root/workspace (default: current directory)
# -i: Docker image to run (default: ${WORKER_IMAGE_NAME:-cmux-worker:0.0.1})
# --rebuild: Force docker build using Dockerfile at repo root and tag the image
# --insiders: Use VS Code Insiders settings directory

WORKSPACE_DIR=$(pwd)
IMAGE_NAME=${WORKER_IMAGE_NAME:-cmux-worker:0.0.1}
USE_INSIDERS=0
FORCE_REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      WORKSPACE_DIR="$2"; shift; shift ;;
    -i|--image)
      IMAGE_NAME="$2"; shift; shift ;;
    --rebuild)
      FORCE_REBUILD=1; shift ;;
    --insiders)
      USE_INSIDERS=1; shift ;;
    -h|--help)
      echo "Usage: $0 [-w <workspace-dir>] [-i <image>] [--rebuild] [--insiders]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ $FORCE_REBUILD -eq 1 ]; then
  echo "Rebuilding image $IMAGE_NAME ..."
  docker build -t "$IMAGE_NAME" -f Dockerfile .
fi

# Detect host VS Code User settings directory
detect_vscode_user_dir() {
  local primary=""
  local fallback=""
  local user_home="$HOME"
  local ostype
  ostype=$(uname -s)
  case "$ostype" in
    Darwin)
      primary=$([ $USE_INSIDERS -eq 1 ] && echo "$user_home/Library/Application Support/Code - Insiders/User" || echo "$user_home/Library/Application Support/Code/User")
      fallback=$([ $USE_INSIDERS -eq 1 ] && echo "$user_home/Library/Application Support/Code/User" || echo "$user_home/Library/Application Support/Code - Insiders/User")
      ;;
    Linux)
      primary=$([ $USE_INSIDERS -eq 1 ] && echo "$user_home/.config/Code - Insiders/User" || echo "$user_home/.config/Code/User")
      fallback=$([ $USE_INSIDERS -eq 1 ] && echo "$user_home/.config/Code/User" || echo "$user_home/.config/Code - Insiders/User")
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Best-effort Windows path (Git Bash/Cygwin)
      primary=$([ $USE_INSIDERS -eq 1 ] && echo "$user_home/AppData/Roaming/Code - Insiders/User" || echo "$user_home/AppData/Roaming/Code/User")
      fallback=$([ $USE_INSIDERS -eq 1 ] && echo "$user_home/AppData/Roaming/Code/User" || echo "$user_home/AppData/Roaming/Code - Insiders/User")
      ;;
    *)
      primary="$user_home/.config/Code/User"
      fallback="$user_home/.config/Code - Insiders/User" ;;
  esac

  if [ -d "$primary" ]; then
    echo "$primary"
  else
    if [ -n "$fallback" ] && [ -d "$fallback" ]; then
      echo "$fallback"
    else
      echo "" # not found
    fi
  fi
}

VSCODE_USER_DIR=$(detect_vscode_user_dir)

# Detect host VS Code extensions directory
detect_vscode_ext_dir() {
  local user_home="$HOME"
  local dir=""
  local ostype
  ostype=$(uname -s)
  case "$ostype" in
    Darwin)
      if [ $USE_INSIDERS -eq 1 ]; then
        dir="$user_home/.vscode-insiders/extensions"
      else
        dir="$user_home/.vscode/extensions"
      fi
      ;;
    Linux)
      if [ $USE_INSIDERS -eq 1 ]; then
        dir="$user_home/.vscode-insiders/extensions"
      else
        dir="$user_home/.vscode/extensions"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if [ $USE_INSIDERS -eq 1 ]; then
        dir="$user_home/.vscode-insiders/extensions"
      else
        dir="$user_home/.vscode/extensions"
      fi
      ;;
    *)
      dir="$user_home/.vscode/extensions" ;;
  esac
  if [ -d "$dir" ]; then
    echo "$dir"
  else
    echo ""
  fi
}

VSCODE_EXT_DIR=$(detect_vscode_ext_dir)

# Detect host appearance to set VSCODE_THEME for explicit theme resolution
detect_host_theme() {
  local ostype
  ostype=$(uname -s)
  if [ "$ostype" = "Darwin" ]; then
    if defaults read -g AppleInterfaceStyle 2>/dev/null | grep -qi "dark"; then
      echo dark; return
    else
      echo light; return
    fi
  elif command -v gsettings >/dev/null 2>&1; then
    local cs
    cs=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "'default'")
    if echo "$cs" | grep -qi dark; then echo dark; else echo light; fi
    return
  fi
  echo dark # safe default to avoid unwanted light theme
}

HOST_APPEARANCE=$(detect_host_theme)

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "Workspace directory does not exist: $WORKSPACE_DIR" >&2
  exit 1
fi

CONTAINER_NAME="cmux-vscode-debug-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 6)"
echo "Starting container $CONTAINER_NAME from image $IMAGE_NAME"

RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  -p 0:39378
  -p 0:39377
  -p 0:39376
  -e WORKER_PORT=39377
  -e HOST_VSCODE_SYNC_MODE=watch
  -e VSCODE_THEME=$HOST_APPEARANCE
  -v "$WORKSPACE_DIR:/root/workspace:rw"
)

if [ -n "$VSCODE_USER_DIR" ]; then
  RUN_ARGS+=( -v "$VSCODE_USER_DIR:/host-vscode/User:ro" -e HOST_VSCODE_USER_DIR=/host-vscode/User )
fi
if [ -n "$VSCODE_EXT_DIR" ]; then
  RUN_ARGS+=( -v "$VSCODE_EXT_DIR:/host-vscode/extensions:ro" -e HOST_VSCODE_EXT_DIR=/host-vscode/extensions )
fi

if [ -n "$VSCODE_USER_DIR" ]; then
  echo "Syncing VS Code settings from: $VSCODE_USER_DIR"
  RUN_ARGS+=(
    -v "$VSCODE_USER_DIR:/host-vscode/User:ro"
    -e HOST_VSCODE_USER_DIR=/host-vscode/User
  )
else
  echo "Warning: Could not find local VS Code settings; using defaults"
fi

docker run "${RUN_ARGS[@]}" "$IMAGE_NAME" >/dev/null

# Find mapped port for OpenVSCode
VSCODE_PORT=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "39378/tcp") 0).HostPort}}' "$CONTAINER_NAME")
WORKER_PORT=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "39377/tcp") 0).HostPort}}' "$CONTAINER_NAME")

URL="http://localhost:${VSCODE_PORT}/?folder=/root/workspace"
echo "OpenVSCode is starting at: $URL"
echo "Worker management port: http://localhost:${WORKER_PORT}"

# Wait for VS Code to be ready (best effort)
for i in $(seq 1 30); do
  if curl -s -f "$URL" >/dev/null 2>&1; then
    echo "Ready: $URL"
    break
  fi
  sleep 0.5
done

echo
echo "To stop and remove the container: docker rm -f $CONTAINER_NAME"
