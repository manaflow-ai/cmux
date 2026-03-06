#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
TAG="xcframework-$GHOSTTY_SHA"
URL="https://github.com/manaflow-ai/ghostty/releases/download/$TAG/GhosttyKit.xcframework.tar.gz"
ARCHIVE_PATH="$ROOT_DIR/GhosttyKit.xcframework.tar.gz"
TARGET_PATH="$ROOT_DIR/GhosttyKit.xcframework"
MAX_RETRIES="${GHOSTTYKIT_DOWNLOAD_MAX_RETRIES:-30}"
RETRY_DELAY="${GHOSTTYKIT_DOWNLOAD_RETRY_DELAY:-20}"

download_prebuilt() {
  local attempt
  local http_code

  echo "Preparing GhosttyKit.xcframework for ghostty $GHOSTTY_SHA"
  echo "Trying pre-built release $TAG"

  for attempt in $(seq 1 "$MAX_RETRIES"); do
    http_code="$(
      curl \
        --silent \
        --show-error \
        --location \
        --output "$ARCHIVE_PATH" \
        --write-out "%{http_code}" \
        "$URL" || true
    )"

    if [ "$http_code" = "200" ]; then
      echo "Download succeeded on attempt $attempt"
      return 0
    fi

    rm -f "$ARCHIVE_PATH"

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ] || [ "$http_code" = "404" ]; then
      echo "Pre-built release unavailable (HTTP $http_code); falling back to local build"
      break
    fi

    if [ "$attempt" -eq "$MAX_RETRIES" ]; then
      break
    fi
    echo "Attempt $attempt/$MAX_RETRIES failed with HTTP ${http_code:-000}, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
  done

  rm -f "$ARCHIVE_PATH"
  return 1
}

extract_prebuilt() {
  rm -rf "$TARGET_PATH"
  tar xzf "$ARCHIVE_PATH"
  rm -f "$ARCHIVE_PATH"
  test -d "$TARGET_PATH"
}

ensure_zig() {
  if command -v zig >/dev/null 2>&1; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    brew install zig
    return 0
  fi

  echo "zig is required to build GhosttyKit.xcframework. Install zig and retry." >&2
  exit 1
}

build_locally() {
  echo "Pre-built release not available; building GhosttyKit.xcframework locally"
  ensure_zig
  rm -rf "$TARGET_PATH"
  (
    cd ghostty
    zig build -Demit-xcframework=true -Demit-macos-app=false -Doptimize=ReleaseFast
  )
  cp -R ghostty/macos/GhosttyKit.xcframework "$TARGET_PATH"
  test -d "$TARGET_PATH"
}

if download_prebuilt; then
  extract_prebuilt
else
  build_locally
fi
