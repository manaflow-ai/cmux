#!/usr/bin/env bash
# TUI for tracking beads issues with search and label filtering
# Run from anywhere in the cmux repo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUI_DIR="${SCRIPT_DIR}/bd-tui"

# Install dependencies if needed
if [ ! -d "${TUI_DIR}/node_modules" ]; then
  echo "Installing bd-tui dependencies..."
  (cd "${TUI_DIR}" && bun install)
fi

# Run the TUI
exec bun run "${TUI_DIR}/index.tsx"
