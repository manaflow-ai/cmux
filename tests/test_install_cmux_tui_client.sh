#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-client-install.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/Test.app"
mkdir -p "$APP/Contents"
CLIENT="$TEST_DIR/client"
cat > "$CLIENT" <<'SH'
#!/bin/sh
[ "$1" = remote-probe ] && [ "$2" = --json ] || exit 64
printf '%s\n' '{"app":"cmux-tui","capabilities":["wireguard-hub","test-capability"]}'
SH
chmod +x "$CLIENT"

install_client() {
  # Exercise the runner's system Bash: macOS ships 3.2, whose nounset handling
  # differs from modern Bash for an initialized but empty array.
  CMUX_TUI_CLIENT_LOCAL="$CLIENT" /bin/bash \
    "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$APP" "$@"
}

install_client
cmp "$CLIENT" "$APP/Contents/Resources/bin/cmux-tui"
install_client --require-capability wireguard-hub
install_client --require-capability wireguard-hub --require-capability test-capability
if install_client --require-capability wireguard-hub --require-capability missing > "$TEST_DIR/missing.log" 2>&1; then
  echo "FAIL: installed a client missing a required capability" >&2
  exit 1
fi
grep -q 'required cmux-tui capability is missing: missing' "$TEST_DIR/missing.log"
echo "PASS: client installation with zero, one, and multiple required capabilities"
