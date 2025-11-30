#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Building cmux CLI (release)..."
cd "${PKG_ROOT}"
cargo build --release --bin cmux

SOURCE_BINARY="${PKG_ROOT}/target/release/cmux"
TARGET_NAME="cmux"

if [ ! -f "$SOURCE_BINARY" ]; then
  echo "❌ Build failed: Binary not found at $SOURCE_BINARY"
  exit 1
fi

echo "✅ Build successful!"

# Determine install directory
# Priority: $HOME/.local/bin -> $HOME/bin -> /usr/local/bin
if [[ -d "$HOME/.local/bin" ]]; then
  INSTALL_DIR="$HOME/.local/bin"
elif [[ -d "$HOME/bin" ]]; then
  INSTALL_DIR="$HOME/bin"
else
  INSTALL_DIR="/usr/local/bin"
fi

DEST="$INSTALL_DIR/$TARGET_NAME"

echo "Copying binary to $DEST..."

if cp "$SOURCE_BINARY" "$DEST" 2>/dev/null; then
  echo "✅ Installed $TARGET_NAME to $INSTALL_DIR"
else
  echo "⚠️  Permission denied. Attempting to install with sudo..."
  sudo cp "$SOURCE_BINARY" "$DEST"
  echo "✅ Installed $TARGET_NAME to $INSTALL_DIR (via sudo)"
fi

# On macOS, remove quarantine attribute and re-sign to prevent "killed" on launch
if [[ "$(uname)" == "Darwin" ]]; then
  xattr -d com.apple.provenance "$DEST" 2>/dev/null || true
  codesign -s - -f "$DEST" 2>/dev/null || true
fi