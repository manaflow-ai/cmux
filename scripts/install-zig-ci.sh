#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"

if command -v zig >/dev/null 2>&1; then
  INSTALLED_ZIG_VERSION="$(zig version 2>/dev/null || true)"
  if [ "$INSTALLED_ZIG_VERSION" = "$ZIG_REQUIRED" ]; then
    echo "zig ${ZIG_REQUIRED} already installed"
    exit 0
  fi
fi

case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if ! command -v minisign >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install minisign
  else
    echo "minisign is required to verify Zig downloads" >&2
    exit 1
  fi
fi

ZIG_NAME="zig-${ZIG_ARCH}-macos-${ZIG_REQUIRED}"
ZIG_TAR="/tmp/${ZIG_NAME}.tar.xz"
ZIG_SIG="${ZIG_TAR}.minisig"
ZIG_DIR="/tmp/${ZIG_NAME}"
ZIG_OFFICIAL_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_NAME}.tar.xz"
ZIG_MIRROR_URL="${ZIG_MIRROR_URL:-https://zigmirror.hryx.net/zig/${ZIG_NAME}.tar.xz}"

download_file() {
  local url="$1"
  local output="$2"
  curl \
    --fail \
    --location \
    --show-error \
    --connect-timeout 20 \
    --max-time 300 \
    --retry 8 \
    --retry-all-errors \
    --retry-delay 10 \
    --retry-max-time 300 \
    "$url" \
    --output "$output"
}

echo "Installing verified zig ${ZIG_REQUIRED}"
rm -f "$ZIG_TAR" "$ZIG_SIG"
if ! download_file "$ZIG_MIRROR_URL" "$ZIG_TAR"; then
  echo "Mirror download failed; retrying from ${ZIG_OFFICIAL_URL}" >&2
  download_file "$ZIG_OFFICIAL_URL" "$ZIG_TAR"
fi
if ! download_file "${ZIG_MIRROR_URL}.minisig" "$ZIG_SIG"; then
  echo "Mirror signature download failed; retrying from ${ZIG_OFFICIAL_URL}.minisig" >&2
  download_file "${ZIG_OFFICIAL_URL}.minisig" "$ZIG_SIG"
fi
minisign -Vm "$ZIG_TAR" -x "$ZIG_SIG" -P "$ZIG_MINISIGN_PUBLIC_KEY"

rm -rf "$ZIG_DIR"
tar xf "$ZIG_TAR" -C /tmp
sudo mkdir -p /usr/local/bin /usr/local/lib
sudo rm -rf /usr/local/lib/zig
sudo mkdir -p /usr/local/lib/zig
sudo cp -f "${ZIG_DIR}/zig" /usr/local/bin/zig
sudo cp -Rf "${ZIG_DIR}/lib/." /usr/local/lib/zig/
zig version
