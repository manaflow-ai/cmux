#!/usr/bin/env bash
# scripts/cmux-next/check-cloud-tunnel-bundle.sh against built fake app bundles:
# a correct one passes, and each defect that gives System Settings a grey or
# blank row (or makes macOS refuse the extension) fails with its reason.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo/scripts/cmux-next/check-cloud-tunnel-bundle.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cloud-tunnel-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
pb() { /usr/libexec/PlistBuddy "$@" >/dev/null; }

make_app() {
  local app="$work/$1/cmux NIGHTLY.app" id="com.cmuxterm.app.nightly"
  local ext="$app/Contents/Library/SystemExtensions/$id.tunnel.systemextension"
  mkdir -p "$app/Contents/Resources" "$ext/Contents/MacOS"
  printf 'icns' > "$app/Contents/Resources/AppIcon-Nightly.icns"
  printf '#!/bin/sh\n' > "$ext/Contents/MacOS/cmux-cloud-tunnel" && chmod +x "$ext/Contents/MacOS/cmux-cloud-tunnel"
  pb -c "Add :CFBundleIdentifier string $id" -c "Add :CFBundleName string cmux NIGHTLY" \
     -c "Add :CFBundleIconFile string AppIcon-Nightly" -c "Add :CFBundleVersion string 4161217392901" \
     -c "Add :CFBundleShortVersionString string 1.0.0" "$app/Contents/Info.plist"
  pb -c "Add :CFBundleIdentifier string $id.tunnel" -c "Add :CFBundlePackageType string SYSX" \
     -c "Add :CFBundleDisplayName string cmux Cloud Tunnel" -c "Add :CFBundleExecutable string cmux-cloud-tunnel" \
     -c "Add :NSSystemExtensionUsageDescription string Reach your Cloud machines." \
     -c "Add :CFBundleVersion string 4161217392901" -c "Add :CFBundleShortVersionString string 1.0.0" \
     -c "Add :NetworkExtension:NEMachServiceName string 7WLXT3NR37.$id.tunnel" \
     -c "Add :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel string cmux_cloud_tunnel.PacketTunnelProvider" \
     "$ext/Contents/Info.plist"
  printf '%s\n' "$app"
}

failures=0
expect() {
  local want="$1" name="$2" app="$3" pattern="${4:-}"; shift 4 || true
  local output status=0
  output="$("$check" "$app" "$@" 2>&1)" || status=$?
  if [[ "$want" == pass && $status -ne 0 ]] || [[ "$want" == fail && $status -eq 0 ]]; then
    echo "FAIL $name: expected $want, got exit $status: $output"; failures=$((failures + 1)); return
  fi
  if [[ -n "$pattern" && "$output" != *"$pattern"* ]]; then
    echo "FAIL $name: output lacks '$pattern': $output"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

good="$(make_app good)"
expect pass "a correct bundle" "$good" "ok (com.cmuxterm.app.nightly.tunnel"

app="$(make_app no-subtitle)"; pb -c "Delete :CFBundleDisplayName" "$app/Contents/Library/SystemExtensions/"*/Contents/Info.plist
expect fail "no subtitle" "$app" "CFBundleDisplayName"

app="$(make_app no-icon)"; rm "$app/Contents/Resources/AppIcon-Nightly.icns"
expect fail "the app's icon file is missing" "$app" "AppIcon-Nightly.icns"

app="$(make_app wrong-id)"; pb -c "Set :CFBundleIdentifier com.cmuxterm.app.tunnel" "$app/Contents/Library/SystemExtensions/"*/Contents/Info.plist
expect fail "an extension id not under the app's" "$app" "plus .tunnel"

app="$(make_app wrong-name)"; mv "$app/Contents/Library/SystemExtensions/"*.systemextension "$app/Contents/Library/SystemExtensions/cmux-cloud-tunnel.systemextension"
expect fail "a bundle not named after its id" "$app" "requires com.cmuxterm.app.nightly.tunnel.systemextension"

app="$(make_app old-version)"; pb -c "Set :CFBundleVersion 12886.2" "$app/Contents/Library/SystemExtensions/"*/Contents/Info.plist
expect fail "an extension version that differs from the app's" "$app" "CFBundleVersion"

app="$(make_app mach)"; pb -c "Set :NetworkExtension:NEMachServiceName com.cmuxterm.app.nightly.tunnel" "$app/Contents/Library/SystemExtensions/"*/Contents/Info.plist
expect fail "a Mach service without the team prefix" "$app" "NEMachServiceName"

app="$(make_app missing)"; rm -rf "$app/Contents/Library/SystemExtensions/"*
expect fail "no extension" "$app" "holds no .systemextension"
expect pass "no extension, allowed" "$app" "" --allow-missing

((failures == 0)) || { echo "$failures check(s) failed"; exit 1; }
echo "all cloud tunnel bundle checks passed"
