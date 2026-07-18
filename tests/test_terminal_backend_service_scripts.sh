#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$ROOT/scripts/lib/mobile-attach.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-terminal-backend-scripts.XXXXXX")"
PASS_TAG="backend-service-pass-$$"
FAIL_TAG="backend-service-fail-$$"
INACTIVE_TAG="backend-service-inactive-$$"
LEGACY_TAG="backend-service-legacy-$$"
MIXED_TAG="backend-service-mixed-$$"
WRONG_ID_TAG="backend-service-wrong-id-$$"
MUTATING_TAG="backend-service-mutating-$$"
cleanup() {
  if [[ "${CMUX_KEEP_TEST_ROOT:-0}" == "1" ]]; then
    printf 'preserved test root: %s\n' "$TEST_ROOT" >&2
    return
  fi
  rm -rf "$TEST_ROOT"
  rm -rf \
    "/tmp/cmux-$PASS_TAG" \
    "/tmp/cmux-$FAIL_TAG" \
    "/tmp/cmux-$INACTIVE_TAG" \
    "/tmp/cmux-$LEGACY_TAG" \
    "/tmp/cmux-$MIXED_TAG" \
    "/tmp/cmux-$WRONG_ID_TAG" \
    "/tmp/cmux-$MUTATING_TAG"
  rm -f "/tmp/cmux-debug-$PASS_TAG.sock" "/tmp/cmux-debug-$PASS_TAG.log" "/tmp/cmux-reload-$PASS_TAG.log"
  rm -f "/tmp/cmux-debug-$FAIL_TAG.sock" "/tmp/cmux-debug-$FAIL_TAG.log" "/tmp/cmux-reload-$FAIL_TAG.log"
  rm -f "/tmp/cmux-debug-$INACTIVE_TAG.sock" "/tmp/cmux-debug-$INACTIVE_TAG.log" "/tmp/cmux-reload-$INACTIVE_TAG.log"
  rm -f "/tmp/cmux-debug-$LEGACY_TAG.sock" "/tmp/cmux-debug-$LEGACY_TAG.log" "/tmp/cmux-reload-$LEGACY_TAG.log"
  rm -f "/tmp/cmux-debug-$MIXED_TAG.sock" "/tmp/cmux-debug-$MIXED_TAG.log" "/tmp/cmux-reload-$MIXED_TAG.log"
  rm -f "/tmp/cmux-debug-$WRONG_ID_TAG.sock" "/tmp/cmux-debug-$WRONG_ID_TAG.log" "/tmp/cmux-reload-$WRONG_ID_TAG.log"
  rm -f "/tmp/cmux-debug-$MUTATING_TAG.sock" "/tmp/cmux-debug-$MUTATING_TAG.log" "/tmp/cmux-reload-$MUTATING_TAG.log"
}
trap cleanup EXIT

bash -n \
  "$ROOT/scripts/audit-terminal-renderer-linkage.sh" \
  "$ROOT/scripts/build-terminal-backend.sh" \
  "$ROOT/scripts/build-terminal-renderer.sh" \
  "$ROOT/scripts/cleanup-dev-builds.sh" \
  "$ROOT/scripts/configure-terminal-backend-launch-agent.sh" \
  "$ROOT/scripts/reload.sh" \
  "$ROOT/scripts/reloads.sh" \
  "$ROOT/scripts/sign-cmux-bundle.sh" \
  "$ROOT/scripts/test-terminal-renderer-helper.sh" \
  "$ROOT/scripts/verify-terminal-backend-service-artifact.sh"

"$ROOT/scripts/terminal-backend-identity.py" --check-vectors
first_fingerprint="$("$ROOT/scripts/terminal-backend-build-fingerprint.py" --metadata test=service-scripts)"
second_fingerprint="$("$ROOT/scripts/terminal-backend-build-fingerprint.py" --metadata test=service-scripts)"
[[ "$first_fingerprint" == "$second_fingerprint" ]]
[[ ${#first_fingerprint} -eq 64 ]]
"$ROOT/scripts/terminal-backend-build-fingerprint.py" \
  --metadata test=dependency-file \
  --dependency-file "$TEST_ROOT/backend.d" \
  --dependency-target "$TEST_ROOT/cmux-terminal-backend" >/dev/null
grep -q 'cmux-tui/crates/cmux-tui-core/src/server.rs' "$TEST_ROOT/backend.d"
grep -q 'ghostty/src/terminal' "$TEST_ROOT/backend.d"
grep -q 'scripts/audit-terminal-renderer-linkage.sh' "$TEST_ROOT/backend.d"
grep -q 'Packages/macOS/CmuxTerminalRenderer' "$TEST_ROOT/backend.d"
grep -q 'scripts/build-terminal-renderer.sh' "$ROOT/cmux.xcodeproj/project.pbxproj"
grep -q 'UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/cmux-terminal-renderer' \
  "$ROOT/cmux.xcodeproj/project.pbxproj"
grep -Fq 'cmux Ghostty worker semantic-scene render' \
  "$ROOT/ghostty/src/renderer/metal/Frame.zig"
grep -Fq 'Ghostty terminal glyph render pass' \
  "$ROOT/ghostty/src/renderer/metal/RenderPass.zig"
grep -Fq 'Ghostty IOSurface terminal render target' \
  "$ROOT/ghostty/src/renderer/metal/Target.zig"

"$ROOT/scripts/reload.sh" --help | grep -q -- '--terminal-backend'
grep -q 'CMUX_TERMINAL_BACKEND_ENABLED=YES' "$ROOT/scripts/reload.sh"
grep -q 'CMUX_SOURCE_COMMIT=' "$ROOT/scripts/reload.sh"
grep -q 'CMUX_SOURCE_DIRTY=' "$ROOT/scripts/reload.sh"
/usr/libexec/PlistBuddy -c 'Print :CMUXSourceCommit' "$ROOT/Resources/Info.plist" \
  | grep -Fqx '$(CMUX_SOURCE_COMMIT)'
/usr/libexec/PlistBuddy -c 'Print :CMUXSourceDirty' "$ROOT/Resources/Info.plist" \
  | grep -Fqx '$(CMUX_SOURCE_DIRTY)'
grep -q -- '--smoke-headless' "$ROOT/.github/workflows/ci.yml"
grep -q -- '--smoke-headless' "$ROOT/.github/workflows/release.yml"
grep -q -- '--smoke-headless' "$ROOT/.github/workflows/nightly.yml"
grep -q -- '--smoke-headless' "$ROOT/scripts/reload.sh"

APP="$TEST_ROOT/cmux DEV service.app"
mkdir -p "$APP/Contents/Resources/bin"
FIXTURE_BUILD_ID="1111111111111111111111111111111111111111111111111111111111111111"
cat > "$TEST_ROOT/cmux-terminal-backend.c" <<'C'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--build-id") == 0) {
    puts("1111111111111111111111111111111111111111111111111111111111111111");
  }
  return 0;
}
C
xcrun clang \
  -Werror \
  -Wl,-no_adhoc_codesign \
  "$TEST_ROOT/cmux-terminal-backend.c" \
  -o "$APP/Contents/Resources/bin/cmux-terminal-backend"
chmod +x "$APP/Contents/Resources/bin/cmux-terminal-backend"
printf '%s\n' "$FIXTURE_BUILD_ID" \
  > "$APP/Contents/Resources/bin/cmux-terminal-backend.build-id"
cp \
  "$APP/Contents/Resources/bin/cmux-terminal-backend" \
  "$APP/Contents/Resources/bin/cmux-terminal-renderer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cmuxterm.app.debug.renderer-a</string>
  <key>CMUXTerminalBackendServiceEnabled</key><string>YES</string>
</dict></plist>
PLIST
"$ROOT/scripts/configure-terminal-backend-launch-agent.sh" \
  --app-bundle "$APP" \
  --bundle-id com.cmuxterm.app.debug.renderer-a
/usr/bin/codesign \
  --force \
  --identifier com.cmuxterm.cmux-terminal-backend \
  --sign - \
  --options runtime \
  --timestamp=none \
  --generate-entitlement-der \
  --entitlements "$ROOT/Resources/cmux-terminal-backend.entitlements" \
  "$APP/Contents/Resources/bin/cmux-terminal-backend" >/dev/null
/usr/bin/codesign \
  --force \
  --identifier com.cmuxterm.cmux-terminal-renderer \
  --sign - \
  --options runtime \
  --timestamp=none \
  --generate-entitlement-der \
  --entitlements "$ROOT/Resources/cmux-terminal-backend.entitlements" \
  "$APP/Contents/Resources/bin/cmux-terminal-renderer" >/dev/null
"$ROOT/scripts/verify-terminal-backend-service-artifact.sh" \
  --app-bundle "$APP" \
  --bundle-id com.cmuxterm.app.debug.renderer-a \
  --require-enabled \
  --require-signed \
  --require-minimal-entitlements
if "$ROOT/scripts/verify-terminal-backend-service-artifact.sh" \
  --app-bundle "$APP" \
  --bundle-id com.cmuxterm.app.debug.renderer-a \
  --require-disabled >/dev/null 2>&1; then
  echo "enabled backend unexpectedly passed --require-disabled" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c 'Set :CMUXTerminalBackendServiceEnabled NO' "$APP/Contents/Info.plist"
"$ROOT/scripts/verify-terminal-backend-service-artifact.sh" \
  --app-bundle "$APP" \
  --bundle-id com.cmuxterm.app.debug.renderer-a \
  --require-disabled \
  --require-signed \
  --require-minimal-entitlements

cat > "$TEST_ROOT/maintenance-fixture.swift" <<'SWIFT'
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else { exit(64) }
let executable = URL(fileURLWithPath: arguments[0])
let stateURL = URL(fileURLWithPath: arguments[0] + ".state")
let unregisterURL = URL(fileURLWithPath: arguments[0] + ".unregister")
let mutateURL = URL(fileURLWithPath: arguments[0] + ".mutate")

switch arguments[1] {
case "--terminal-backend-service-status":
    let state = try String(contentsOf: stateURL, encoding: .utf8)
    print(state.trimmingCharacters(in: .whitespacesAndNewlines))
    if FileManager.default.fileExists(atPath: mutateURL.path) {
        let infoPlist = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: infoPlist.path
        )
        try FileManager.default.removeItem(at: mutateURL)
    }
case "--unregister-terminal-backend-service":
    let value = try String(contentsOf: unregisterURL, encoding: .utf8)
    let status = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
    if status == 0 {
        try "not-registered\n".write(to: stateURL, atomically: true, encoding: .utf8)
    }
    exit(status)
default:
    exit(64)
}
SWIFT
xcrun swiftc \
  "$TEST_ROOT/maintenance-fixture.swift" \
  -o "$TEST_ROOT/maintenance-fixture"

make_cleanup_fixture() {
  local tag="$1"
  local service_status="$2"
  local unregister_status="$3"
  local mutate_on_status="${4:-0}"
  local derived="$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$tag"
  local app="$derived/Build/Products/Debug/cmux DEV $tag.app"
  local bundle_id
  local service_label
  local executable="$app/Contents/MacOS/cmux DEV"
  bundle_id="$(cmux_attach_mac_bundle_id "$tag")"
  service_label="$($ROOT/scripts/terminal-backend-identity.py \
    --bundle-id "$bundle_id" \
    --field serviceLabel)"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
  cp "$TEST_ROOT/maintenance-fixture" "$executable"
  printf '%s\n' "$service_status" > "$executable.state"
  printf '%s\n' "$unregister_status" > "$executable.unregister"
  if [[ "$mutate_on_status" -eq 1 ]]; then
    touch "$executable.mutate"
  fi
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>cmux DEV</string>
  <key>CMUXTerminalBackendServiceStatusCommand</key><string>--terminal-backend-service-status</string>
  <key>CMUXTerminalBackendServiceUnregisterCommand</key><string>--unregister-terminal-backend-service</string>
</dict></plist>
PLIST
  cat > "$app/Contents/Library/LaunchAgents/$service_label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>$service_label</string>
</dict></plist>
PLIST
  chmod +x "$executable"
}

make_cleanup_fixture "$PASS_TAG" enabled 0
make_cleanup_fixture "$FAIL_TAG" enabled 70
make_cleanup_fixture "$INACTIVE_TAG" not-registered 0
make_cleanup_fixture "$MIXED_TAG" enabled 0
mixed_info="$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$MIXED_TAG/Build/Products/Debug/cmux DEV $MIXED_TAG.app/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Delete :CMUXTerminalBackendServiceUnregisterCommand' \
  "$mixed_info"
make_cleanup_fixture "$WRONG_ID_TAG" enabled 0
wrong_info="$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$WRONG_ID_TAG/Build/Products/Debug/cmux DEV $WRONG_ID_TAG.app/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Set :CFBundleIdentifier com.cmuxterm.app.debug.someone-else' \
  "$wrong_info"
make_cleanup_fixture "$MUTATING_TAG" not-registered 0 1
legacy_derived="$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$LEGACY_TAG"
mkdir -p "$legacy_derived"
cleanup_output="$TEST_ROOT/cleanup-output.txt"
HOME="$TEST_ROOT/home" "$ROOT/scripts/cleanup-dev-builds.sh" --apply >"$cleanup_output" 2>&1
grep -q 'persistent terminal backend' "$cleanup_output"
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$PASS_TAG" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$FAIL_TAG" ]]
[[ ! -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$INACTIVE_TAG" ]]
[[ ! -d "$legacy_derived" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$MIXED_TAG" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$WRONG_ID_TAG" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$MUTATING_TAG" ]]
grep -q 'maintenance identity is unsafe' "$cleanup_output"
grep -q 'changed after planning' "$cleanup_output"

HOME="$TEST_ROOT/home" "$ROOT/scripts/cleanup-dev-builds.sh" \
  --apply \
  --keep "$MUTATING_TAG" \
  --terminate-terminal-backends >"$cleanup_output" 2>&1
grep -q 'terminates every PTY' "$cleanup_output"
[[ ! -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$PASS_TAG" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$FAIL_TAG" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$MIXED_TAG" ]]
[[ -d "$TEST_ROOT/home/Library/Developer/Xcode/DerivedData/cmux-$WRONG_ID_TAG" ]]
grep -q "skipped: $FAIL_TAG" "$cleanup_output"

echo "terminal backend service scripts verified"
