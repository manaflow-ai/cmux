#!/usr/bin/env bash

set -e

mkdir -p ./logs
DATETIME="$(date '+%Y%m%d-%H%M%S')"

echo "Starting setup..."
echo "Logs: ./logs/*-$DATETIME.log"
echo ""

# Run bun install and uv sync in parallel
echo "[1/2] Installing dependencies (bun install + uv sync)..."
bun install >"./logs/bun-install-$DATETIME.log" 2>&1 &
BUN_PID=$!
uv sync >"./logs/uv-sync-$DATETIME.log" 2>&1 &
UV_PID=$!

BUN_OK=0
UV_OK=0
wait $BUN_PID || BUN_OK=1
wait $UV_PID || UV_OK=1

if [ $BUN_OK -ne 0 ]; then
  echo "      bun install failed (see ./logs/bun-install-$DATETIME.log)"
  exit 1
fi
if [ $UV_OK -ne 0 ]; then
  echo "      uv sync failed (see ./logs/uv-sync-$DATETIME.log)"
  exit 1
fi
echo "      done"

# Run convex setup (depends on bun install)
echo "[2/2] convex setup..."
if bun run convex:setup >"./logs/convex-setup-$DATETIME.log" 2>&1; then
  echo "      done"
else
  echo "      failed (see ./logs/convex-setup-$DATETIME.log)"
  exit 1
fi

echo ""
echo "Setup complete! Run ./scripts/dev.sh to start the dev server."
