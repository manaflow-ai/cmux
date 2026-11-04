#!/usr/bin/env bash
# scripts/cmux-next/embed-cloud-tunnel.sh is the only step that puts the Cloud Tunnel
# system extension into the app. A Release build without CMUX_CLOUD_TUNNEL=YES must
# never have it in the bundle (Xcode's ValidateEmbeddedBinary failed on an extension
# that a Copy Files phase embedded and this script then removed), and no Copy Files
# phase of the Xcode project may embed it. A build that ships the tunnel embeds the
# built extension. Stamp, codesign and the bundle check are stubbed: they have their
# own tests (test_check_cloud_tunnel_bundle.sh).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/embed-cloud-tunnel.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# The script under test beside stubs of the scripts it calls, and a codesign stub on PATH.
mkdir -p "$work/scripts" "$work/bin"
cp "$repo/scripts/cmux-next/embed-cloud-tunnel.sh" "$work/scripts/"
for stub in stamp-cloud-tunnel-identity.sh check-cloud-tunnel-bundle.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$stub" "$work" > "$work/scripts/$stub"
  chmod +x "$work/scripts/$stub"
done
sed -i.bak 's#/usr/bin/codesign#codesign#; s#/usr/bin/ditto#cp -R#' "$work/scripts/embed-cloud-tunnel.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/codesign" && chmod +x "$work/bin/codesign"

build() { # build NAME CONFIGURATION CMUX_CLOUD_TUNNEL
  local products="$work/$1/products" app="$work/$1/products/cmux.app"
  mkdir -p "$app/Contents" "$products/cmux-cloud-tunnel.systemextension/Contents"
  printf 'plist' > "$products/cmux-cloud-tunnel.systemextension/Contents/Info.plist"
  PATH="$work/bin:$PATH" CONFIGURATION="$2" CMUX_CLOUD_TUNNEL="$3" BUILT_PRODUCTS_DIR="$products" \
    "$work/scripts/embed-cloud-tunnel.sh" "$app" > "$work/$1/out" 2>&1 || echo "exit $?" >> "$work/$1/out"
  echo "$app/Contents/Library/SystemExtensions"
}

dir="$(build release-off Release NO)"
[[ ! -e "$dir" ]] || fail "a Release build without CMUX_CLOUD_TUNNEL=YES has $dir"
grep -q "^exit" "$work/release-off/out" && fail "a Release build without the tunnel failed: $(cat "$work/release-off/out")"

dir="$(build release-off-stale Release NO)"
mkdir -p "$dir/old.systemextension"
build release-off-stale Release NO > /dev/null
[[ ! -e "$dir" ]] || fail "a Release build without the tunnel kept a previous build's extension"

dir="$(build release-on Release YES)"
[[ -f "$dir/cmux-cloud-tunnel.systemextension/Contents/Info.plist" ]] \
  || fail "a Release build with CMUX_CLOUD_TUNNEL=YES did not embed the built extension: $(cat "$work/release-on/out")"

dir="$(build debug Debug NO)"
[[ -f "$dir/cmux-cloud-tunnel.systemextension/Contents/Info.plist" ]] \
  || fail "a Debug build did not embed the built extension: $(cat "$work/debug/out")"

# No Copy Files phase embeds the extension: only the script decides.
if grep -q "systemextension in Embed System Extensions" "$repo/cmux.xcodeproj/project.pbxproj"; then
  fail "cmux.xcodeproj embeds cmux-cloud-tunnel.systemextension in a Copy Files phase; Xcode then validates a bundle a Release build does not ship"
fi

[[ "$failures" -eq 0 ]] || { echo "$failures failure(s)" >&2; exit 1; }
echo "embed-cloud-tunnel: ok"
