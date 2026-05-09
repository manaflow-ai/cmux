#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZERO_NATIVE_DIR="$ROOT/third_party/zero-native"

if [ ! -d "$ZERO_NATIVE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/vercel-labs/zero-native.git "$ZERO_NATIVE_DIR"
fi

if command -v zero-native >/dev/null 2>&1; then
  ZERO_NATIVE_CLI=(zero-native)
else
  npm install --prefix "$ZERO_NATIVE_DIR/packages/zero-native"
  ZERO_NATIVE_CLI=(node "$ZERO_NATIVE_DIR/packages/zero-native/bin/zero-native.js")
fi

"${ZERO_NATIVE_CLI[@]}" cef install --dir "$ROOT/third_party/cef/macos"

echo "Ready. Run:"
echo "  cd experiments/zero-native-cmux"
echo "  zig build run"
