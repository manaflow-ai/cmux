#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/install-prebuilt-ghostty-cli-helper.sh <helper-path> <app-path>
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

HELPER_PATH="$1"
APP_PATH="$2"
DEST_PATH="$APP_PATH/Contents/Resources/bin/ghostty"

if [[ ! -f "$HELPER_PATH" ]]; then
  echo "error: Ghostty CLI helper not found at $HELPER_PATH" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST_PATH")"
install -m 755 "$HELPER_PATH" "$DEST_PATH"

lipo "$DEST_PATH" -verify_arch arm64 x86_64
echo "Installed universal Ghostty CLI helper at $DEST_PATH"
