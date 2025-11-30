#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> Rebuilding and installing dmux CLI (debug)..."
"${SCRIPT_DIR}/build-cli-debug.sh"

echo ""
echo ">>> Restarting Sandbox Server..."
"${SCRIPT_DIR}/dmux-cli.sh" server restart

echo ""
echo "✅ Dev environment reloaded!"
