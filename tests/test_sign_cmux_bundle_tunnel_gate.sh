#!/usr/bin/env bash
# cmux-next ships no Cloud tunnel system extension. Release signing must fail
# before codesign when the entitlements still request the tunnel or the bundle
# still carries Contents/Library/SystemExtensions, and the shipped channel
# entitlements must not request it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

sign() {
  "$ROOT/scripts/sign-cmux-bundle.sh" "$1" "$2" "Developer ID Application: Test" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err"
}

# 1. Entitlements that request the tunnel are refused.
APP="$TMP_DIR/one/cmux.app"
mkdir -p "$APP/Contents"
cat > "$TMP_DIR/tunnel.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.networking.networkextension</key>
	<array>
		<string>packet-tunnel-provider-systemextension</string>
	</array>
	<key>com.apple.developer.system-extension.install</key>
	<true/>
</dict>
</plist>
PLIST
if sign "$APP" "$TMP_DIR/tunnel.entitlements"; then
  echo "FAIL: signing accepted entitlements that request the Cloud tunnel" >&2
  exit 1
fi
grep -q "requests the Cloud tunnel system extension" "$TMP_DIR/err" || {
  echo "FAIL: signing did not fail at the tunnel entitlement gate" >&2
  sed -n '1,80p' "$TMP_DIR/err" >&2
  exit 1
}

# 2. A bundled system extension is refused.
APP="$TMP_DIR/two/cmux.app"
mkdir -p "$APP/Contents/Library/SystemExtensions/x.systemextension"
if sign "$APP" "$ROOT/cmux.release.entitlements"; then
  echo "FAIL: signing accepted a bundle with Contents/Library/SystemExtensions" >&2
  exit 1
fi
grep -q "ships no system extension" "$TMP_DIR/err" || {
  echo "FAIL: signing did not fail at the system extension gate" >&2
  sed -n '1,80p' "$TMP_DIR/err" >&2
  exit 1
}

# 3. The channel entitlements do not request the tunnel.
for file in cmux.release.entitlements cmux.nightly.entitlements cmux.rc.entitlements; do
  if grep -Eq "networking\.networkextension|system-extension\.install" "$ROOT/$file"; then
    echo "FAIL: $file still requests the Cloud tunnel" >&2
    exit 1
  fi
done

echo "PASS: sign-cmux-bundle.sh tunnel gate"
