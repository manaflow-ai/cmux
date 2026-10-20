#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: verify-app-bundle-licenses.sh <app-path>

Verifies that a built cmux app contains the canonical project GPL and its
third-party license notices before the app is placed in a distributed DMG.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$1"
RESOURCES_PATH="$APP_PATH/Contents/Resources"
SOURCE_LICENSE="$ROOT_DIR/LICENSE"
BUNDLED_LICENSE="$RESOURCES_PATH/LICENSE"
BUNDLED_THIRD_PARTY="$RESOURCES_PATH/THIRD_PARTY_LICENSES.md"

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [[ ! -s "$BUNDLED_LICENSE" ]]; then
  echo "error: cmux project license missing or empty at $BUNDLED_LICENSE" >&2
  exit 1
fi

if ! cmp -s "$SOURCE_LICENSE" "$BUNDLED_LICENSE"; then
  echo "error: bundled cmux project license differs from $SOURCE_LICENSE" >&2
  exit 1
fi

if [[ ! -s "$BUNDLED_THIRD_PARTY" ]]; then
  echo "error: third-party licenses missing or empty at $BUNDLED_THIRD_PARTY" >&2
  exit 1
fi

echo "verified app bundle licenses: $APP_PATH"
