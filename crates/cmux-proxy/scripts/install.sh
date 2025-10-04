#!/usr/bin/env bash
set -euo pipefail

# Simple installer for cmux-proxy on Linux.
# Defaults:
# - Installs to /usr/local/bin (override with CMUX_PROXY_BIN_DIR)
# - Fetches latest release (override with CMUX_PROXY_VERSION, e.g. v0.1.0)

REPO="lawrencecchen/cmux-proxy"
BIN_NAME="cmux-proxy"
BIN_DIR="${CMUX_PROXY_BIN_DIR:-/usr/local/bin}"
VERSION="${CMUX_PROXY_VERSION:-latest}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

need_cmd uname
need_cmd tar
if command -v curl >/dev/null 2>&1; then
  DL="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
  DL="wget -qO-"
else
  echo "Need curl or wget to download releases" >&2
  exit 1
fi

arch=$(uname -m)
case "$arch" in
  x86_64|amd64)
    target="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64)
    target="aarch64-unknown-linux-gnu" ;;
  *)
    echo "Unsupported architecture: $arch" >&2
    echo "You can build from source: \n  cargo build --release && sudo cp target/release/${BIN_NAME} ${BIN_DIR}" >&2
    exit 1 ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

asset_latest="${BIN_NAME}-${target}.tar.gz"
if [ "$VERSION" = "latest" ]; then
  url="https://github.com/${REPO}/releases/latest/download/${asset_latest}"
else
  # Expect a tag like v0.1.0
  asset_versioned="${BIN_NAME}-${VERSION}-${target}.tar.gz"
  url="https://github.com/${REPO}/releases/download/${VERSION}/${asset_versioned}"
fi

echo "Downloading: $url"
if [[ "$DL" == curl* ]]; then
  curl -fL "$url" -o "$tmpdir/release.tar.gz"
else
  wget -q "$url" -O "$tmpdir/release.tar.gz"
fi

echo "Extracting binary"
tar -xzf "$tmpdir/release.tar.gz" -C "$tmpdir"
if [ ! -f "$tmpdir/${BIN_NAME}" ]; then
  echo "Expected ${BIN_NAME} in archive but not found" >&2
  exit 1
fi
chmod +x "$tmpdir/${BIN_NAME}"

mkdir -p "$BIN_DIR"
dest="$BIN_DIR/${BIN_NAME}"

if [ -w "$BIN_DIR" ]; then
  cp "$tmpdir/${BIN_NAME}" "$dest"
else
  echo "Escalating permissions to write to $BIN_DIR"
  need_cmd sudo
  sudo cp "$tmpdir/${BIN_NAME}" "$dest"
fi

echo "Installed $dest"
"$dest" --version || true
