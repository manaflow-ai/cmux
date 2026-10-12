#!/usr/bin/env bash
# phone-install.sh — build an unsigned device app on the build Mac, sign it on
# this Mac with the team's API development certificate and the
# "cmux next native dev (agent)" profile, and install it on a USB/Wi-Fi paired
# iPhone through this Mac's Xcode (devicectl). The build Mac's keychain is
# locked over SSH, so signing happens here.
#
#   phone-install.sh [--device <udid>] [--no-install]
set -euo pipefail
HOST="${CMUX_NATIVE_BUILD_HOST:-aziz-other-macbook}"
DEVICE=00008150-0005154E0E84401C
PROFILE_ID="${CMUX_NATIVE_PROFILE_ID:-9XBF5GGK9D}"
INSTALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${CMUX_NATIVE_BUILDS:-$HOME/cmux-native-builds}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

cd "$ROOT/native-mobile/ios" && xcodegen generate --quiet
rsync -az --delete --exclude .build "$ROOT/native-mobile/" "$HOST:cmux-native/work/native-mobile/"
rsync -az --delete "$ROOT/Packages/Shared/CmuxGhosttyKit/" "$HOST:cmux-native/work/Packages/Shared/CmuxGhosttyKit/"
ssh "$HOST" 'set -e; cd ~/cmux-native/work/native-mobile/ios
  xcodebuild -project CmuxNative.xcodeproj -scheme CmuxNative -configuration Debug -destination generic/platform=iOS \
    -derivedDataPath ~/cmux-native/dd-ios-dev CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
  cd ~/cmux-native/dd-ios-dev/Build/Products/Debug-iphoneos && rm -f /tmp/CmuxNative-unsigned.zip && ditto -c -k --keepParent CmuxNative.app /tmp/CmuxNative-unsigned.zip'
scp -q "$HOST:/tmp/CmuxNative-unsigned.zip" "$WORK/app.zip"
ditto -x -k "$WORK/app.zip" "$WORK"
APP="$WORK/CmuxNative.app"
asc --profile "cmux-shared Team Key" --strict-auth profiles download --id "$PROFILE_ID" --output "$WORK/app.mobileprovision" >/dev/null
cp "$WORK/app.mobileprovision" "$APP/embedded.mobileprovision"
security cms -D -i "$WORK/app.mobileprovision" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$WORK/ent.plist"
/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$WORK/ent.plist"
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" -c "Add :keychain-access-groups:0 string 7WLXT3NR37.dev.cmux.next.native.dev" "$WORK/ent.plist"
ID=$(security find-identity -v -p codesigning | awk '/Created via API/ {print $2; exit}')
for f in "$APP"/Frameworks/*; do codesign -f -s "$ID" --timestamp=none "$f"; done
codesign -f -s "$ID" --entitlements "$WORK/ent.plist" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$OUT" && (cd "$WORK" && mkdir Payload && cp -R CmuxNative.app Payload/ && zip -qry "$OUT/cmux-next-native-dev.ipa" Payload)
echo "built $OUT/cmux-next-native-dev.ipa"
if [[ $INSTALL == 1 ]]; then
  xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "bundleID|installationURL"
fi
