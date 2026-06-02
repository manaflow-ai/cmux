#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OWL_LAYER_HOST_SELF_TEST_OUT:-$ROOT_DIR/artifacts/layer-host-self-test-gui-latest}"
LABEL="com.manaflow.owlselftest"
UID_VALUE="$(id -u)"
APP_DIR="/tmp/OwlLayerHostSelfTest.app"

create_app_bundle() {
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR/Contents/MacOS"
  cp "$ROOT_DIR/.build/release/OwlLayerHostSelfTest" "$APP_DIR/Contents/MacOS/OwlLayerHostSelfTest"
  cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>OwlLayerHostSelfTest</string>
  <key>CFBundleIdentifier</key><string>com.manaflow.OwlLayerHostSelfTest</string>
  <key>CFBundleName</key><string>OwlLayerHostSelfTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
}

run_mode() {
  local mode="$1"
  local mode_dir="$OUT_DIR/$mode"
  local label="$LABEL.$mode.$$"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local stdout_log="/tmp/owl-self-test-$mode-$$.out"
  local stderr_log="/tmp/owl-self-test-$mode-$$.err"

  rm -rf "$mode_dir"
  mkdir -p "$mode_dir" "$HOME/Library/LaunchAgents"
  rm -f "$stdout_log" "$stderr_log"

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-W</string>
    <string>$APP_DIR</string>
    <string>--args</string>
    <string>--output-dir</string>
    <string>$mode_dir</string>
    <string>--mode</string>
    <string>$mode</string>
    <string>--timeout</string>
    <string>20</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$stdout_log</string>
  <key>StandardErrorPath</key><string>$stderr_log</string>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$UID_VALUE/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_VALUE" "$plist"
  for _ in {1..25}; do
    if [ -f "$mode_dir/summary.json" ]; then
      break
    fi
    sleep 1
  done
  launchctl bootout "gui/$UID_VALUE/$label" 2>/dev/null || true

  echo "== $mode stdout =="
  cat "$stdout_log" 2>/dev/null || true
  echo "== $mode stderr =="
  cat "$stderr_log" 2>/dev/null || true

  if [ ! -f "$mode_dir/summary.json" ]; then
    echo "Missing summary for $mode in $mode_dir" >&2
    exit 1
  fi
}

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"
swift build -c release --product OwlLayerHostSelfTest
create_app_bundle
run_mode direct
run_mode layer-host

echo "Artifacts: $OUT_DIR"
