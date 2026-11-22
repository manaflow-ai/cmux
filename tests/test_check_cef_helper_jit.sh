#!/usr/bin/env bash
# scripts/cmux-next/check-cef-helper-jit.sh on small ad hoc signed bundles: a
# hardened plain helper with no allow-jit (the NIGHTLY 4178064067101 SIGTRAP
# crashes) fails, in the app and in the remote browser host; helpers signed as
# sign-cef.sh signs them pass. Needs codesign, so it runs on macOS only.
set -Eeuo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: codesign needs macOS"
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-cef-helper-jit.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cef-jit-check.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

JIT="$TEST_DIR/jit.entitlements"
NONE="$TEST_DIR/none.entitlements"
write_entitlements() { # <file> <key>
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' "<key>$2</key><true/>" '</dict></plist>' > "$1"
}
write_entitlements "$JIT" com.apple.security.cs.allow-jit
write_entitlements "$NONE" com.apple.security.cs.disable-library-validation

# make_helper <frameworks dir> <bundle name> jit|none|unhardened
make_helper() {
  local dir="$1/$2.app" mode="$3"
  mkdir -p "$dir/Contents/MacOS"
  cp /usr/bin/true "$dir/Contents/MacOS/helper"
  plutil -create xml1 "$dir/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string helper "$dir/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "test.${2// /-}" "$dir/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$dir/Contents/Info.plist"
  case "$mode" in
    jit) codesign --force --sign - --options runtime --entitlements "$JIT" "$dir" 2>/dev/null ;;
    none) codesign --force --sign - --options runtime --entitlements "$NONE" "$dir" 2>/dev/null ;;
    unhardened) codesign --force --sign - "$dir" 2>/dev/null ;;
  esac
}

# make_app <path> <plain helper mode> [<remote host plain helper mode>]
make_app() {
  local app="$1" fw="$1/Contents/Frameworks"
  mkdir -p "$fw"
  make_helper "$fw" "cmux Helper" "$2"
  make_helper "$fw" "cmux Helper (Renderer)" jit
  make_helper "$fw" "cmux Helper (GPU)" jit
  make_helper "$fw" "cmux Helper (Alerts)" none
  make_helper "$fw" "cmux Helper (Plugin)" none
  if [[ -n "${3:-}" ]]; then
    local host_fw="$app/Contents/Helpers/cmux-remote-browser-host.app/Contents/Frameworks"
    mkdir -p "$host_fw"
    make_helper "$host_fw" "cmux-remote-browser-host Helper" "$3"
    make_helper "$host_fw" "cmux-remote-browser-host Helper (Renderer)" jit
  fi
}

pass=0
expect() { # <0|1> <app> <label>
  local want="$1" app="$2" label="$3" got=0
  "$CHECK" "$app" > "$TEST_DIR/out.log" 2>&1 || got=$?
  if [[ "$got" -ne "$want" ]]; then
    echo "FAIL: $label: exit $got, want $want" >&2
    cat "$TEST_DIR/out.log" >&2
    exit 1
  fi
  echo "PASS: $label"
  pass=$((pass + 1))
}

make_app "$TEST_DIR/good.app" jit jit
expect 0 "$TEST_DIR/good.app" "helpers signed as sign-cef.sh signs them"

make_app "$TEST_DIR/plain-no-jit.app" none
expect 1 "$TEST_DIR/plain-no-jit.app" "hardened plain helper without allow-jit"
grep -q "cmux Helper.app has the hardened runtime and no com.apple.security.cs.allow-jit" "$TEST_DIR/out.log" \
  || { echo "FAIL: the error does not name the plain helper" >&2; cat "$TEST_DIR/out.log" >&2; exit 1; }

make_app "$TEST_DIR/host-no-jit.app" jit none
expect 1 "$TEST_DIR/host-no-jit.app" "remote browser host plain helper without allow-jit"
grep -q "cmux-remote-browser-host Helper.app" "$TEST_DIR/out.log" \
  || { echo "FAIL: the error does not name the browser host helper" >&2; cat "$TEST_DIR/out.log" >&2; exit 1; }

make_app "$TEST_DIR/unhardened.app" unhardened
expect 0 "$TEST_DIR/unhardened.app" "a plain helper without the hardened runtime needs no entitlement"

mkdir -p "$TEST_DIR/nocef.app/Contents/MacOS"
expect 0 "$TEST_DIR/nocef.app" "an app with no Chromium helpers"

echo "OK: $pass cases"
