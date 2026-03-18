#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${1:-0.15.2}"
ZIG_PLATFORM="${2:-aarch64-macos}"

case "${ZIG_REQUIRED}:${ZIG_PLATFORM}" in
  0.15.2:aarch64-macos)
    ZIG_URL="https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
    ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
    ZIG_DIR="/tmp/zig-aarch64-macos-0.15.2"
    ;;
  *)
    echo "Unsupported Zig install target: ${ZIG_REQUIRED}:${ZIG_PLATFORM}" >&2
    exit 1
    ;;
esac

if command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -q "^${ZIG_REQUIRED}$"; then
  ZIG_ENV_JSON="$(zig env 2>/dev/null || true)"
  ZIG_LIB_DIR="$(printf '%s\n' "$ZIG_ENV_JSON" | sed -n 's/.*"lib_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -n "$ZIG_LIB_DIR" ] && [ -d "$ZIG_LIB_DIR" ]; then
    echo "zig ${ZIG_REQUIRED} already installed"
    exit 0
  fi
  echo "zig ${ZIG_REQUIRED} binary is present but lib_dir is missing, reinstalling"
fi

echo "Installing zig ${ZIG_REQUIRED} from tarball"
ARCHIVE="/tmp/zig.tar.xz"
curl -fSL "$ZIG_URL" -o "$ARCHIVE"

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$ZIG_SHA256" ]; then
  echo "zig ${ZIG_REQUIRED} checksum mismatch" >&2
  echo "Expected: $ZIG_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

rm -rf "$ZIG_DIR"
tar xf "$ARCHIVE" -C /tmp

sudo mkdir -p /usr/local/bin /usr/local/lib
sudo rm -f /usr/local/bin/zig
sudo rm -rf /usr/local/lib/zig
sudo cp -f "$ZIG_DIR/zig" /usr/local/bin/zig
sudo cp -R "$ZIG_DIR/lib" /usr/local/lib/zig

export PATH="/usr/local/bin:$PATH"
zig version
