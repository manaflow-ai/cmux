#!/usr/bin/env bash
# The engine verifier must reject the stub bridge and accept the real one.
# The stub is built here (clang only); the real engine half runs when Go is
# installed and is skipped otherwise.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/scripts/verify-tunnel-extension-engine.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Stub archive (no Go on purpose) is rejected.
CMUX_WIREGUARD_GO_BINARY=/nonexistent/go CMUX_WIREGUARD_GO_REQUIRE=0 \
  CMUX_WIREGUARD_GO_OUTPUT="$TMP_DIR/stub.a" TARGET_TEMP_DIR="$TMP_DIR/stub-tmp" ARCHS="arm64" \
  "$ROOT/scripts/build-wireguard-go.sh" >/dev/null 2>&1
if "$VERIFIER" "$TMP_DIR/stub.a" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted the stub bridge" >&2; exit 1
fi

# 2. A file that is not Mach-O at all is rejected.
printf 'not a binary\n' > "$TMP_DIR/text"
if "$VERIFIER" "$TMP_DIR/text" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted a non-Mach-O file" >&2; exit 1
fi

# 3. The real engine is accepted (only when Go is available).
export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/go/bin:${PATH}"
if command -v go >/dev/null 2>&1; then
  CMUX_WIREGUARD_GO_REQUIRE=1 CMUX_WIREGUARD_GO_OUTPUT="$TMP_DIR/real.a" TARGET_TEMP_DIR="$TMP_DIR/real-tmp" ARCHS="$(uname -m | sed 's/aarch64/arm64/')" \
    "$ROOT/scripts/build-wireguard-go.sh" >/dev/null 2>&1
  "$VERIFIER" "$TMP_DIR/real.a" >/dev/null
  echo "PASS: verify-tunnel-extension-engine.sh (stub rejected, real engine accepted)"
else
  echo "PASS: verify-tunnel-extension-engine.sh (stub rejected; real-engine half skipped, no Go)"
fi
