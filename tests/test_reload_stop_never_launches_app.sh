#!/usr/bin/env bash
# Regression test: reload.sh stopped the previous tagged instance with
# `osascript -e 'tell application id "<bundle>" to quit'`. When the app was not
# running, that Apple Event made LaunchServices LAUNCH it, and LaunchServices
# picked the raw xcodebuild product (Build/Products/Debug/cmux DEV.app, same
# bundle id, no LSEnvironment, no agent env). The follow-up pkill matched only
# "cmux DEV <tag>.app", so that stray survived, took the tag's debug socket in
# normal mode and could activate over the user's app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=scripts/lib/stop-app-instances.sh
source "$ROOT_DIR/scripts/lib/stop-app-instances.sh"
declare -F cmux_stop_app_instances >/dev/null || fail "cmux_stop_app_instances not found"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# LaunchServices refuses to launch bundles in temporary directories, so the
# probe lives in the user's caches like a DerivedData product would.
mkdir -p "$HOME/Library/Caches"
TMP_DIR="$(mktemp -d "$HOME/Library/Caches/cmux-stop-app-test.XXXXXX")"
SUFFIX="$(basename "$TMP_DIR" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')"
BUNDLE_ID="com.cmuxterm.test.stopapp.${SUFFIX}"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true; done
  [[ -d "$TMP_DIR/launch/cmux DEV.app" ]] && "$LSREGISTER" -u "$TMP_DIR/launch/cmux DEV.app" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

write_plist() {
  local plist="$1" bundle_id="$2"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleExecutable</key><string>cmux DEV</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSAppleScriptEnabled</key><true/>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
}

# 1. Nothing runs: stopping must not start the app. The bundle is registered
# with LaunchServices under the id, as xcodebuild registers its product; its
# executable only records that it was started. Like cmux it is scriptable
# without a static dictionary, so an Apple Event to it launches it to ask for
# its terminology (and the sender then waits out the two-minute reply timeout).
products="$TMP_DIR/launch"
marker="$TMP_DIR/launched"
raw_app="$products/cmux DEV.app"
write_plist "$raw_app/Contents/Info.plist" "$BUNDLE_ID"
mkdir -p "$raw_app/Contents/MacOS"
printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$raw_app/Contents/MacOS/cmux DEV"
chmod +x "$raw_app/Contents/MacOS/cmux DEV"
"$LSREGISTER" -f "$raw_app" >/dev/null 2>&1 || fail "could not register the probe bundle"
cmux_stop_app_instances "$BUNDLE_ID" "$products/cmux DEV probe.app/Contents/MacOS/cmux DEV" \
  "$raw_app/Contents/MacOS/cmux DEV"
[[ ! -e "$marker" ]] || fail "stopping a tag that was not running launched its app through LaunchServices"
echo "PASS: stopping a tag that is not running launches nothing"

# 2. A stray runs from the raw xcodebuild product with the tag's bundle id: it
# must stop. A same-named product of another bundle id (a shared DerivedData
# built for another tag) must keep running.
start_fake() {
  local app="$1" bundle_id="$2"
  write_plist "$app/Contents/Info.plist" "$bundle_id"
  # A copied platform binary is killed by launch constraints; name a plain
  # sleep after the executable path instead, which is what pgrep -f sees.
  # Detached (launchd reaps it), so kill -0 reports the real exit, not a zombie.
  ( bash -c 'exec -a "$1" /bin/sleep 600' _ "$app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 &
    echo "$!" > "$TMP_DIR/pid" )
  PIDS+=("$(cat "$TMP_DIR/pid")")
}
start_fake "$TMP_DIR/stray/cmux DEV.app" "$BUNDLE_ID"
stray_pid="${PIDS[${#PIDS[@]}-1]}"
start_fake "$TMP_DIR/other/cmux DEV.app" "${BUNDLE_ID}.other"
other_pid="${PIDS[${#PIDS[@]}-1]}"
cmux_stop_app_instances "$BUNDLE_ID" "$TMP_DIR/stray/cmux DEV probe.app/Contents/MacOS/cmux DEV" \
  "$TMP_DIR/stray/cmux DEV.app/Contents/MacOS/cmux DEV"
! kill -0 "$stray_pid" 2>/dev/null || fail "a stray running from the raw xcodebuild product survived the stop"
kill -0 "$other_pid" 2>/dev/null || fail "the stop killed a process of another bundle id"
echo "PASS: the stop ends a stray from the raw xcodebuild product and nothing else"
