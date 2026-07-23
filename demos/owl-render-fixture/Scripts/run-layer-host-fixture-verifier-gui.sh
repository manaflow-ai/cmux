#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${OWL_CHROMIUM_HOST:-$HOME/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell}"
RUNTIME="${OWL_MOJO_RUNTIME_PATH:-$HOME/chromium/src/out/Release/libowl_fresh_mojo_runtime.dylib}"
OUT_DIR="${OWL_LAYER_HOST_FIXTURE_OUT:-$ROOT_DIR/artifacts/layer-host-fixture-gui-latest}"
CHROMIUM_OUT="$(cd "$(dirname "$RUNTIME")" && pwd)"
LABEL="com.manaflow.owllayerfixture.$$"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STDOUT_LOG="/tmp/owl-layer-fixture-$$.out"
STDERR_LOG="/tmp/owl-layer-fixture-$$.err"
UID_VALUE="$(id -u)"
APP_DIR="/tmp/OwlLayerHostVerifier.app"

if [ ! -x "$HOST" ]; then
  echo "Missing Chromium host executable: $HOST" >&2
  exit 1
fi

if [ ! -f "$RUNTIME" ]; then
  echo "Missing OWL Mojo runtime dylib: $RUNTIME" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$HOME/Library/LaunchAgents"
rm -f "$STDOUT_LOG" "$STDERR_LOG"

cd "$ROOT_DIR"
swift build -c release --product OwlLayerHostVerifier

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT_DIR/.build/release/OwlLayerHostVerifier" "$APP_DIR/Contents/MacOS/OwlLayerHostVerifier"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>OwlLayerHostVerifier</string>
  <key>CFBundleIdentifier</key><string>com.manaflow.OwlLayerHostVerifier</string>
  <key>CFBundleName</key><string>OwlLayerHostVerifier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSEnvironment</key>
  <dict>
    <key>OWL_FRESH_LAYER_FIXTURE</key><string>1</string>
    <key>DYLD_LIBRARY_PATH</key><string>$CHROMIUM_OUT</string>
  </dict>
</dict>
</plist>
PLIST

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-W</string>
    <string>$APP_DIR</string>
    <string>--args</string>
    <string>--chromium-host</string>
    <string>$HOST</string>
    <string>--mojo-runtime</string>
    <string>$RUNTIME</string>
    <string>--output-dir</string>
    <string>$OUT_DIR</string>
    <string>--skip-example</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key><string>$STDERR_LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
for _ in {1..50}; do
  if [ -f "$OUT_DIR/summary.json" ]; then
    break
  fi
  sleep 1
done
launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true

echo "== stdout =="
cat "$STDOUT_LOG" 2>/dev/null || true
echo "== stderr =="
cat "$STDERR_LOG" 2>/dev/null || true

if [ ! -f "$OUT_DIR/summary.json" ]; then
  if [ -f "$OUT_DIR/fatal-error.txt" ]; then
    echo "== fatal-error =="
    cat "$OUT_DIR/fatal-error.txt"
  fi
  for failure in "$OUT_DIR"/*-failure.json; do
    if [ -f "$failure" ]; then
      echo "== $failure =="
      cat "$failure"
    fi
  done
  echo "Missing summary in $OUT_DIR" >&2
  exit 1
fi

echo "Artifacts: $OUT_DIR"
