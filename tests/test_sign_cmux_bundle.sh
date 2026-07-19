#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
BIN_DIR="$APP/Contents/Resources/bin"
mkdir -p "$APP/Contents/MacOS" "$BIN_DIR"

SOURCE="$TMP_DIR/main.c"
printf '%s\n' 'int main(void) { return 0; }' > "$SOURCE"
for binary in \
  "$APP/Contents/MacOS/cmux" \
  "$BIN_DIR/cmux" \
  "$BIN_DIR/cmux-codex-hook-client" \
  "$BIN_DIR/cmux-agent-hook-supervisor"
do
  xcrun clang -mmacosx-version-min=14.0 -Os "$SOURCE" -o "$binary"
done

APP_ENTITLEMENTS="$TMP_DIR/app.entitlements"
HELPER_ENTITLEMENTS="$TMP_DIR/helper.entitlements"
python3 - \
  "$APP/Contents/Info.plist" \
  "$APP_ENTITLEMENTS" \
  "$HELPER_ENTITLEMENTS" <<'PY'
import plistlib
import sys

info_path, app_entitlements_path, helper_entitlements_path = sys.argv[1:]
with open(info_path, "wb") as handle:
    plistlib.dump(
        {
            "CFBundleExecutable": "cmux",
            "CFBundleIdentifier": "com.cmuxterm.signature-test",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        },
        handle,
    )
with open(app_entitlements_path, "wb") as handle:
    plistlib.dump(
        {"com.apple.developer.web-browser.public-key-credential": True},
        handle,
    )
with open(helper_entitlements_path, "wb") as handle:
    plistlib.dump(
        {
            "com.apple.security.cs.allow-jit": True,
            "com.apple.security.cs.allow-unsigned-executable-memory": True,
            "com.apple.security.cs.disable-library-validation": True,
        },
        handle,
    )
PY

CMUX_TIMESTAMP=none \
CMUX_HELPER_ENTITLEMENTS="$HELPER_ENTITLEMENTS" \
CMUX_VERIFY_COMMAND_PALETTE_TOOL=/usr/bin/true \
CMUX_VERIFY_DIFF_SIDECAR_TOOL=/usr/bin/true \
  "$ROOT/scripts/sign-cmux-bundle.sh" "$APP" "$APP_ENTITLEMENTS" -

GENERIC_ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$BIN_DIR/cmux" 2>&1)"
if ! grep -Fq 'com.apple.security.cs.allow-jit' <<<"$GENERIC_ENTITLEMENTS"; then
  echo "generic CLI helper did not receive the configured helper entitlements" >&2
  exit 1
fi

for helper_name in cmux-codex-hook-client cmux-agent-hook-supervisor; do
  helper="$BIN_DIR/$helper_name"
  "$ROOT/scripts/verify-hook-helper-signature.sh" "$helper"
done

for forbidden in \
  com.apple.application-identifier \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation
do
  bad_helper="$TMP_DIR/${forbidden##*.}"
  bad_entitlements="$bad_helper.entitlements"
  cp "$BIN_DIR/cmux-codex-hook-client" "$bad_helper"
  python3 - "$bad_entitlements" "$forbidden" <<'PY'
import plistlib
import sys

path, key = sys.argv[1:]
value = "TEAMID.com.cmuxterm.signature-test" if key.endswith("application-identifier") else True
with open(path, "wb") as handle:
    plistlib.dump({key: value}, handle)
PY
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign - \
    --entitlements "$bad_entitlements" \
    "$bad_helper"

  output="$TMP_DIR/${forbidden##*.}.log"
  if "$ROOT/scripts/verify-hook-helper-signature.sh" "$bad_helper" >"$output" 2>&1; then
    echo "hook helper verifier accepted forbidden entitlement: $forbidden" >&2
    exit 1
  fi
  reported_forbidden="$forbidden"
  if [[ "$forbidden" == "com.apple.application-identifier" ]]; then
    reported_forbidden="application-identifier"
  fi
  if ! grep -Fq "$reported_forbidden" "$output"; then
    echo "hook helper verifier did not report forbidden entitlement: $forbidden" >&2
    cat "$output" >&2
    exit 1
  fi
done

echo "hook helper signing policy rejects all privileged entitlements"
