#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/remove-sparkle-sandbox-xpc-services.sh <app-path>" >&2
  exit 2
fi

APP_PATH="$1"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  exit 0
fi

find "$SPARKLE_FRAMEWORK" \
  -path '*/XPCServices' \
  \( -type d -o -type l \) \
  -prune \
  -print |
while IFS= read -r xpc_dir; do
  rm -rf "$xpc_dir"
  echo "Removed Sparkle sandbox XPC services: $xpc_dir"
done
