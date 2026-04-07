#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/app.app" >&2
  exit 64
fi

APP_PATH="$1"
EXPECTED_KEY="com.apple.developer.web-browser.public-key-credential"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 66
fi

RAW_OUTPUT="$(mktemp)"
PLIST_OUTPUT="$(mktemp)"
cleanup() {
  rm -f "$RAW_OUTPUT" "$PLIST_OUTPUT"
}
trap cleanup EXIT

/usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$RAW_OUTPUT" 2>&1
awk 'found { print } /^<\?xml/ { found = 1; print }' "$RAW_OUTPUT" >"$PLIST_OUTPUT"

if [ ! -s "$PLIST_OUTPUT" ]; then
  echo "Could not extract entitlements from signed app: $APP_PATH" >&2
  cat "$RAW_OUTPUT" >&2
  exit 1
fi

VALUE="$(/usr/libexec/PlistBuddy -c "Print :$EXPECTED_KEY" "$PLIST_OUTPUT" 2>/dev/null || true)"
if [ "$VALUE" != "true" ]; then
  echo "Missing expected entitlement '$EXPECTED_KEY' on: $APP_PATH" >&2
  cat "$PLIST_OUTPUT" >&2
  exit 1
fi

echo "Verified entitlement '$EXPECTED_KEY' on: $APP_PATH"
