#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Write notary test receipt". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -uo pipefail
out="notary-receipt"
mkdir -p "$out"
{
  echo "run: $GITHUB_RUN_ID attempt ${GITHUB_RUN_ATTEMPT:-1}"
  echo "commit: $BUILD_SHA"
  echo "bundle id: $CHANNEL_BUNDLE_ID"
  echo "production probe: $NOTARY_PROBE"
  echo "import variant: $IMPORT_VARIANT"
  echo "swift flags: ${SWIFT_IMPORT_FLAGS:-none}"
  echo "empty browser-sources.json: $EMPTY_BROWSER_SOURCES"
  echo "notarize step: $NOTARIZE_OUTCOME"
  if [ -f "$NIGHTLY_DMG_RELEASE" ]; then echo "dmg sha256: $(shasum -a 256 "$NIGHTLY_DMG_RELEASE" | cut -d' ' -f1)"; fi
  if [ -f "$NIGHTLY_DMG_RELEASE.notarization.state" ]; then grep -E '^(submission_id|status)=' "$NIGHTLY_DMG_RELEASE.notarization.state" || true; fi
} > "$out/receipt.txt"
[ -f "$NIGHTLY_DMG_RELEASE.notarization.log" ] && cp "$NIGHTLY_DMG_RELEASE.notarization.log" "$out/notarization.log"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CHANNEL_APP_PATH/Contents/Info.plist" > "$out/bundle-id.txt" 2>&1
if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$CHANNEL_APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  echo "SUPublicEDKey present" > "$out/sparkle.txt"
else
  echo "SUPublicEDKey absent (Sparkle disabled)" > "$out/sparkle.txt"
fi
codesign -dvv "$CHANNEL_APP_PATH" > "$out/codesign.txt" 2>&1
xcrun stapler validate "$CHANNEL_APP_PATH" > "$out/stapler-app.txt" 2>&1
[ -f "$NIGHTLY_DMG_RELEASE" ] && xcrun stapler validate "$NIGHTLY_DMG_RELEASE" > "$out/stapler-dmg.txt" 2>&1
spctl -a -vv -t exec "$CHANNEL_APP_PATH" > "$out/spctl-app.txt" 2>&1
[ -f "$NIGHTLY_DMG_RELEASE" ] && spctl -a -vv -t open --context context:primary-signature "$NIGHTLY_DMG_RELEASE" > "$out/spctl-dmg.txt" 2>&1
syspolicy_check distribution "$CHANNEL_APP_PATH" > "$out/syspolicy-check.txt" 2>&1
cat "$out/receipt.txt" "$out/sparkle.txt" "$out/stapler-app.txt"
{ echo "### cx-f58x notary test receipt"; echo '```'; cat "$out/receipt.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
# Receipts are text only: refuse to upload anything else.
if find "$out" -type f ! -name '*.txt' ! -name '*.log' | grep -q .; then echo "non-text receipt file" >&2; exit 1; fi
exit 0

