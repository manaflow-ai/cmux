#!/usr/bin/env bash
set -euo pipefail

# reload-prod.sh - Rebuild and restart the production cmux environment
# Uses release builds and the cmux container (port 46831)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> Rebuilding and installing cmux CLI (release)..."
"${SCRIPT_DIR}/build-cli.sh"

echo ""
echo ">>> Restarting Sandbox Server..."
"${SCRIPT_DIR}/cmux-cli.sh" server restart

echo ""
echo "✅ Production environment reloaded!"
