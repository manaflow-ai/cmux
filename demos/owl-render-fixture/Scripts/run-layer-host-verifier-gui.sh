#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${OWL_CHROMIUM_HOST:-$HOME/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell}"
RUNTIME="${OWL_MOJO_RUNTIME_PATH:-$HOME/chromium/src/out/Release/libowl_fresh_mojo_runtime.dylib}"
OUT_DIR="${OWL_LAYER_HOST_RENDER_OUT:-$ROOT_DIR/artifacts/layer-host-gui-latest}"
TIMEOUT="${OWL_LAYER_HOST_TIMEOUT:-45}"
WAIT_SECONDS="${OWL_LAYER_HOST_WAIT_SECONDS:-140}"
CHROMIUM_OUT="$(cd "$(dirname "$RUNTIME")" && pwd)"
LABEL="com.manaflow.owllayerreal.$$"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STDOUT_LOG="/tmp/owl-layer-real-$$.out"
STDERR_LOG="/tmp/owl-layer-real-$$.err"
UID_VALUE="$(id -u)"
APP_DIR="/tmp/OwlLayerHostVerifier-$LABEL.app"

cleanup_stale_owl_hosts() {
  local pids
  pids="$(pgrep -f "Content Shell.*--fresh-owl-embed" 2>/dev/null || true)"
  if [ -z "$pids" ]; then
    return
  fi

  kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do
    pids="$(pgrep -f "Content Shell.*--fresh-owl-embed" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
      return
    fi
    sleep 0.1
  done
  kill -9 $pids 2>/dev/null || true
}

cleanup_run_artifacts() {
  launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
  cleanup_stale_owl_hosts
}

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
cleanup_stale_owl_hosts
trap cleanup_run_artifacts EXIT

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
  <key>CFBundleIdentifier</key><string>com.manaflow.OwlLayerHostVerifier.run$$</string>
  <key>CFBundleName</key><string>OwlLayerHostVerifier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSEnvironment</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key><string>$CHROMIUM_OUT</string>
PLIST

for env_name in \
  OWL_FRESH_DISABLE_GPU \
  OWL_FRESH_LAYER_FIXTURE \
  OWL_FRESH_ENABLE_DEVTOOLS \
  OWL_FRESH_NO_EMBED \
  OWL_FRESH_NO_IN_PROCESS_GPU \
  OWL_FRESH_WINDOW_SNAPSHOT \
  OWL_LAYER_HOST_FILE_PICKER_CHECK \
  OWL_LAYER_HOST_DEVTOOLS_CHECK \
  OWL_LAYER_HOST_GOOGLE_CHECK \
  OWL_LAYER_HOST_LIFECYCLE_CHECK \
  OWL_LAYER_HOST_ONLY_TARGETS \
  OWL_LAYER_HOST_RECOVERY_CHECK \
  OWL_LAYER_HOST_RESIZE_CHECK \
  OWL_LAYER_HOST_SCALE_CHECK \
  OWL_LAYER_HOST_WIDGET_CHECK \
  OWL_LAYER_HOST_KEY_ONLY; do
  env_value="${!env_name:-}"
  if [ -n "$env_value" ]; then
    cat >> "$APP_DIR/Contents/Info.plist" <<PLIST
    <key>$env_name</key><string>$env_value</string>
PLIST
  fi
done

cat >> "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>--timeout</string>
    <string>$TIMEOUT</string>
PLIST

if [ "${OWL_LAYER_HOST_SKIP_EXAMPLE:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--skip-example</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_SKIP_CANVAS:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--skip-canvas</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_INPUT_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--input-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_RESIZE_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--resize-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_LIFECYCLE_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--lifecycle-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_SCALE_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--scale-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_RECOVERY_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--recovery-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_FILE_PICKER_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--file-picker-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_DEVTOOLS_CHECK:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--devtools-check</string>
PLIST
fi
if [ "${OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE:-}" = "1" ]; then
  cat >> "$PLIST" <<PLIST
    <string>--input-diagnostic-capture</string>
PLIST
fi

cat >> "$PLIST" <<PLIST
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key><string>$STDERR_LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
for ((i = 0; i < WAIT_SECONDS; i++)); do
  if [ -f "$OUT_DIR/summary.json" ]; then
    break
  fi
  sleep 1
done
cleanup_run_artifacts
trap - EXIT

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
