#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${1:-0.15.2}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
ZIG_MINISIGN_PUBLIC_KEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

if command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -q "^${ZIG_REQUIRED}"; then
  echo "zig ${ZIG_REQUIRED} already installed"
  exit 0
fi

case "$(uname -s)" in
  Darwin) ZIG_OS="macos" ;;
  Linux) ZIG_OS="linux" ;;
  *)
    echo "Unsupported OS for Zig install: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64 | amd64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported architecture for Zig install: $(uname -m)" >&2
    exit 1
    ;;
esac

if ! command -v minisign >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew install minisign
  else
    echo "minisign is required to verify Zig downloads" >&2
    exit 1
  fi
fi

download_with_retries() {
  local url="$1"
  local output="$2"
  local attempt
  local max_attempts=5

  rm -f "$output"
  for attempt in $(seq 1 "$max_attempts"); do
    echo "Downloading ${url} (attempt ${attempt}/${max_attempts})"
    if curl --fail --location --show-error --silent --connect-timeout 20 --speed-limit 65536 --speed-time 20 --max-time 120 "$url" --output "$output"; then
      return 0
    fi

    rm -f "$output"
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep $((attempt * 2))
    fi
  done

  return 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

ZIG_BASE="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_REQUIRED}"
ZIG_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_BASE}.tar.xz"
archive="$tmpdir/zig.tar.xz"
signature="$tmpdir/zig.tar.xz.minisig"

echo "Installing verified zig ${ZIG_REQUIRED} from tarball"
download_with_retries "$ZIG_URL" "$archive"
download_with_retries "${ZIG_URL}.minisig" "$signature"
minisign -Vm "$archive" -x "$signature" -P "$ZIG_MINISIGN_PUBLIC_KEY"

tar xf "$archive" -C "$tmpdir"
sudo mkdir -p "${INSTALL_PREFIX}/bin" "${INSTALL_PREFIX}/lib/zig"
sudo rm -rf "${INSTALL_PREFIX}/lib/zig"
sudo mkdir -p "${INSTALL_PREFIX}/lib/zig"
sudo cp -f "${tmpdir}/${ZIG_BASE}/zig" "${INSTALL_PREFIX}/bin/zig"
sudo cp -Rf "${tmpdir}/${ZIG_BASE}/lib/." "${INSTALL_PREFIX}/lib/zig/"

export PATH="${INSTALL_PREFIX}/bin:${PATH}"
zig version
