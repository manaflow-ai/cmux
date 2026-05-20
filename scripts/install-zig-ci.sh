#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"
ZIG_INDEX_URL="${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"
ZIG_EXPECTED_SHA256="${ZIG_EXPECTED_SHA256:-}"
export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"

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

ZIG_NAME="zig-${ZIG_ARCH}-macos-${ZIG_REQUIRED}"
ZIG_TAR="/tmp/${ZIG_NAME}.tar.xz"
ZIG_SIG="${ZIG_TAR}.minisig"
ZIG_DIR="/tmp/${ZIG_NAME}"
ZIG_OFFICIAL_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_NAME}.tar.xz"
ZIG_MIRROR_URL="${ZIG_MIRROR_URL:-https://zigmirror.hryx.net/zig/${ZIG_NAME}.tar.xz}"
ZIG_INDEX_ARCH="${ZIG_ARCH}-macos"

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

resolve_zig_sha256() {
  if [ -n "$ZIG_EXPECTED_SHA256" ]; then
    printf '%s\n' "$ZIG_EXPECTED_SHA256"
    return 0
  fi

  local index_file="/tmp/zig-download-index-${ZIG_REQUIRED}-$$.json"
  download_file "$ZIG_INDEX_URL" "$index_file"
  python3 - "$index_file" "$ZIG_REQUIRED" "$ZIG_INDEX_ARCH" <<'PY'
import json
import sys

index_path, version, arch = sys.argv[1:4]
with open(index_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

try:
    shasum = data[version][arch]["shasum"]
except KeyError as exc:
    raise SystemExit(f"missing Zig checksum for {version} {arch}: {exc}") from exc

if not isinstance(shasum, str) or not shasum:
    raise SystemExit(f"invalid Zig checksum for {version} {arch}")

print(shasum)
PY
  rm -f "$index_file"
}

verify_zig_sha256() {
  local expected_sha256="$1"
  printf '%s  %s\n' "$expected_sha256" "$ZIG_TAR" | shasum -a 256 -c -
}

echo "Installing verified zig ${ZIG_REQUIRED}"
rm -f "$ZIG_TAR" "$ZIG_SIG"
if ! download_file "$ZIG_MIRROR_URL" "$ZIG_TAR"; then
  echo "Mirror download failed; retrying from ${ZIG_OFFICIAL_URL}" >&2
  download_file "$ZIG_OFFICIAL_URL" "$ZIG_TAR"
fi
ZIG_RESOLVED_SHA256="$(resolve_zig_sha256)"
verify_zig_sha256 "$ZIG_RESOLVED_SHA256"

if command -v minisign >/dev/null 2>&1; then
  if ! download_file "${ZIG_MIRROR_URL}.minisig" "$ZIG_SIG"; then
    echo "Mirror signature download failed; retrying from ${ZIG_OFFICIAL_URL}.minisig" >&2
    download_file "${ZIG_OFFICIAL_URL}.minisig" "$ZIG_SIG"
  fi
  minisign -Vm "$ZIG_TAR" -x "$ZIG_SIG" -P "$ZIG_MINISIGN_PUBLIC_KEY"
else
  echo "minisign not found; verified Zig tarball with SHA-256 from ${ZIG_INDEX_URL}"
fi

rm -rf "$ZIG_DIR"
tar xf "$ZIG_TAR" -C /tmp
sudo mkdir -p /usr/local/bin /usr/local/lib
sudo rm -rf /usr/local/lib/zig
sudo mkdir -p /usr/local/lib/zig
sudo cp -f "${ZIG_DIR}/zig" /usr/local/bin/zig
sudo cp -Rf "${ZIG_DIR}/lib/." /usr/local/lib/zig/
zig version
