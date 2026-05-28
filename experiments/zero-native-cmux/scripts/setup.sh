#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZERO_NATIVE_DIR="$ROOT/third_party/zero-native"

if [ ! -d "$ZERO_NATIVE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/vercel-labs/zero-native.git "$ZERO_NATIVE_DIR"
fi

shopt -s nullglob
PATCHES=("$ROOT"/patches/*.patch)
shopt -u nullglob

for PATCH in "${PATCHES[@]}"; do
  if git -C "$ZERO_NATIVE_DIR" apply --check "$PATCH" >/dev/null 2>&1; then
    git -C "$ZERO_NATIVE_DIR" apply "$PATCH"
  elif git -C "$ZERO_NATIVE_DIR" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    :
  else
    echo "Failed to apply Zero Native patch: ${PATCH##*/}" >&2
    exit 1
  fi
done

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
