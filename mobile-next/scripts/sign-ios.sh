#!/usr/bin/env bash
# Runs on this Mac: fetch the unsigned device app from the build mini and sign
# it with the team development identity and profile (never copied to the mini).
#   sign-ios.sh <output-dir>
set -euo pipefail
HOST="${CNM_HOST:-mini-cmux8s-mac-mini}"
OUT="${1:-$HOME/cnm-builds/latest}"
PROFILE="${CNM_PROFILE:-$HOME/cnm-signing/dev.mobileprovision}"
IDENTITY="${CNM_IDENTITY:-0B3075111A8C7028ABD3A92C2514C54F0FE6F73B}"
rm -rf "$OUT" && mkdir -p "$OUT"
scp -q "$HOST:cnm/out/CmuxNext-unsigned.zip" "$OUT/"
ditto -x -k "$OUT/CmuxNext-unsigned.zip" "$OUT/Payload"
APP="$OUT/Payload/CmuxNext.app"
cp "$PROFILE" "$APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > "$OUT/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$OUT/profile.plist" > "$OUT/entitlements.plist"
find "$APP" -name '*.framework' -o -name '*.dylib' | while read -r item; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$item"
done
codesign --force --sign "$IDENTITY" --entitlements "$OUT/entitlements.plist" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
(cd "$OUT" && rm -f CmuxNext.ipa && zip -qry CmuxNext.ipa Payload)
echo "IPA=$OUT/CmuxNext.ipa"
