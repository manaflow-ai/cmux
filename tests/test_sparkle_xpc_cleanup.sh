#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-sparkle-xpc-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

APP_PATH="$WORK_DIR/cmux.app"
SPARKLE_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework"
VERSION_DIR="$SPARKLE_DIR/Versions/B"
XPC_DIR="$VERSION_DIR/XPCServices"

mkdir -p "$XPC_DIR/Installer.xpc" "$XPC_DIR/Downloader.xpc" "$VERSION_DIR/Resources"
touch "$XPC_DIR/Installer.xpc/Info.plist"
touch "$XPC_DIR/Downloader.xpc/Info.plist"
touch "$VERSION_DIR/Resources/keep.txt"
ln -s B "$SPARKLE_DIR/Versions/Current"
ln -s Versions/Current/XPCServices "$SPARKLE_DIR/XPCServices"

"$ROOT_DIR/scripts/remove-sparkle-sandbox-xpc-services.sh" "$APP_PATH" >/dev/null

if [[ -e "$XPC_DIR" ]]; then
  echo "FAIL: Sparkle XPCServices directory was not removed" >&2
  exit 1
fi

if [[ -e "$SPARKLE_DIR/XPCServices" || -L "$SPARKLE_DIR/XPCServices" ]]; then
  echo "FAIL: Sparkle XPCServices symlink was not removed" >&2
  exit 1
fi

if [[ ! -e "$VERSION_DIR/Resources/keep.txt" ]]; then
  echo "FAIL: Sparkle cleanup removed unrelated framework contents" >&2
  exit 1
fi

echo "PASS: Sparkle sandbox XPC services are stripped from non-sandboxed release bundles"
