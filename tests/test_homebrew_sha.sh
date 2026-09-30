#!/bin/bash
# Regression test: verify the Homebrew cask SHA256 matches the actual release DMG.
# This also covers https://github.com/manaflow-ai/cmux/issues/14415: a release
# asset was rebuilt in place, but the cask retained the superseded digest.
set -euo pipefail

FIXTURE_DIR=""
SERVER_PID=""
TMPFILE=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$FIXTURE_DIR" ]; then
    rm -rf "$FIXTURE_DIR"
  fi
  if [ -n "$TMPFILE" ]; then
    rm -f "$TMPFILE"
  fi
}
trap cleanup EXIT

CASK_FILE="${HOMEBREW_SHA_CASK_FILE:-$(dirname "$0")/../homebrew-cmux/Casks/cmux.rb}"
URL_OVERRIDE="${HOMEBREW_SHA_URL:-}"

if [ "${HOMEBREW_SHA_TEST_MODE:-}" = "fixture" ]; then
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-homebrew-sha-fixture.XXXXXX")"
  python3 - "$FIXTURE_DIR" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
payload = (b"cmux deterministic Homebrew checksum fixture\n" * 65536)
(root / "cmux-macos.dmg").write_bytes(payload)
(root / "cmux.rb").write_text(
    'cask "cmux" do\n'
    '  version "fixture"\n'
    f'  sha256 "{hashlib.sha256(payload).hexdigest()}"\n'
    'end\n',
    encoding="utf-8",
)
PY
  PORT_FILE="$FIXTURE_DIR/port"
  python3 - "$FIXTURE_DIR" "$PORT_FILE" >/dev/null 2>&1 <<'PY' &
import http.server
import os
from pathlib import Path
import sys

os.chdir(sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
Path(sys.argv[2]).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
  done
  [ -s "$PORT_FILE" ] || {
    echo "FAIL: deterministic Homebrew checksum fixture server did not start" >&2
    exit 1
  }
  CASK_FILE="$FIXTURE_DIR/cmux.rb"
  URL_OVERRIDE="http://127.0.0.1:$(cat "$PORT_FILE")/cmux-macos.dmg"
  echo "Using deterministic local checksum fixture"
fi

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

URL="${URL_OVERRIDE:-https://github.com/manaflow-ai/cmux/releases/download/v${VERSION}/cmux-macos.dmg}"
TMPFILE=$(mktemp)

# Download with retries + timeouts so a transient GitHub/CDN hiccup (5xx,
# connection reset, DNS blip, truncated transfer) soft-skips instead of
# flaking. Only a successfully downloaded DMG whose SHA mismatches is a real
# failure. Mirrors the soft-pass pattern in test_ci_sparkle_build_monotonic.sh.
HTTP_CODE=$(curl -sL -H 'Cache-Control: no-cache' \
  --retry 3 --retry-delay 2 --retry-all-errors \
  --connect-timeout 20 --max-time 120 \
  -w '%{http_code}' "$URL" -o "$TMPFILE" 2>/dev/null || echo "000")
FILE_SIZE=$(stat -f%z "$TMPFILE" 2>/dev/null || stat --printf="%s" "$TMPFILE" 2>/dev/null || echo 0)

if [ -n "$FIXTURE_DIR" ] && { [ "$HTTP_CODE" != "200" ] || [ "$FILE_SIZE" -lt 1000000 ]; }; then
  echo "FAIL: local checksum fixture could not be downloaded" >&2
  exit 1
fi

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

if [ -n "$FIXTURE_DIR" ]; then
  # Rebuild the same version at the same URL while retaining the old cask SHA.
  printf '\nrebuilt\n' >> "$FIXTURE_DIR/cmux-macos.dmg"
  if HOMEBREW_SHA_TEST_MODE= HOMEBREW_SHA_CASK_FILE="$CASK_FILE" HOMEBREW_SHA_URL="$URL" \
    bash "$0" > "$FIXTURE_DIR/rebuilt.log" 2>&1; then
    cat "$FIXTURE_DIR/rebuilt.log"
    echo "FAIL: rebuilt fixture was incorrectly accepted" >&2
    exit 1
  fi
  grep -q 'FAIL: SHA256 mismatch!' "$FIXTURE_DIR/rebuilt.log" || {
    cat "$FIXTURE_DIR/rebuilt.log"
    echo "FAIL: rebuilt fixture did not reach checksum validation" >&2
    exit 1
  }
  echo "PASS: rebuilt DMG at the same URL rejects the stale cask checksum"
fi
