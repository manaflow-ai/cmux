#!/bin/bash
# Regression test: verify the homebrew cask SHA256 matches the actual release DMG.
# Catches issues like https://github.com/manaflow-ai/cmux/issues/110 where a race
# condition caused the cask to contain the SHA of a 404 page instead of the DMG.
set -euo pipefail

CASK_FILE="$(dirname "$0")/../homebrew-cmux/Casks/cmux.rb"

if [ ! -f "$CASK_FILE" ]; then
  echo "SKIP: homebrew-cmux submodule not initialized"
  exit 0
fi

VERSION=$(grep 'version "' "$CASK_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
CASK_SHA=$(grep 'sha256 "' "$CASK_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$VERSION" ] || [ -z "$CASK_SHA" ]; then
  echo "FAIL: could not parse version/sha256 from $CASK_FILE"
  exit 1
fi

echo "Cask version: $VERSION"
echo "Cask SHA256:  $CASK_SHA"

URL="https://github.com/manaflow-ai/cmux/releases/download/v${VERSION}/cmux-macos.dmg"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# Download with retries + timeouts so a transient GitHub/CDN hiccup (5xx,
# connection reset, DNS blip, truncated transfer) soft-skips instead of
# flaking. Only a successfully downloaded DMG whose SHA mismatches is a real
# failure. Mirrors the soft-pass pattern in test_ci_sparkle_build_monotonic.sh.
HTTP_CODE=$(curl -sL \
  --retry 3 --retry-delay 2 --retry-all-errors \
  --connect-timeout 20 --max-time 120 \
  -w '%{http_code}' "$URL" -o "$TMPFILE" 2>/dev/null || echo "000")
FILE_SIZE=$(stat -f%z "$TMPFILE" 2>/dev/null || stat --printf="%s" "$TMPFILE" 2>/dev/null || echo 0)

if [ "$HTTP_CODE" != "200" ]; then
  case "$HTTP_CODE" in
    000|408|429|5??)
      # Transient transport/server failure (no response, timeout, rate-limit, 5xx):
      # soft-skip so a GitHub/CDN hiccup does not flake the check.
      echo "WARN: transient download failure (HTTP $HTTP_CODE); skipping SHA check"
      echo "PASS (soft): network/transport failure, not a SHA mismatch"
      exit 0
      ;;
    *)
      # Deterministic client-side error (e.g. 404 for a missing/renamed release
      # asset). This is a real regression, not a network blip: fail hard.
      echo "FAIL: release DMG unavailable at expected URL (HTTP $HTTP_CODE)"
      echo "  URL: $URL"
      exit 1
      ;;
  esac
fi

if [ "$FILE_SIZE" -lt 1000000 ]; then
  echo "WARN: downloaded file is only $FILE_SIZE bytes (expected >1MB for a DMG); likely a truncated/transient transfer"
  echo "PASS (soft): incomplete download, not a SHA mismatch"
  exit 0
fi

ACTUAL_SHA=$(shasum -a 256 "$TMPFILE" | cut -d' ' -f1)
echo "Actual SHA256: $ACTUAL_SHA"

if [ "$CASK_SHA" != "$ACTUAL_SHA" ]; then
  echo "FAIL: SHA256 mismatch!"
  echo "  Cask:   $CASK_SHA"
  echo "  Actual: $ACTUAL_SHA"
  exit 1
fi

echo "PASS: homebrew cask SHA256 matches release DMG"
