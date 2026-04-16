#!/usr/bin/env bash
# Rebuild the Monaco Vite bundle that ships inside the macOS app.
#
# Only needs to be run when editing files under monaco-editor/ or bumping the
# monaco-editor dependency. The committed monaco-editor/dist/ output is what
# Xcode copies into the app bundle, so CI never runs npm.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/monaco-editor"

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required to build the monaco bundle" >&2
  exit 1
fi

if [ ! -d node_modules ]; then
  npm ci
fi

npm run build

echo "Built monaco-editor/dist — commit the result."
