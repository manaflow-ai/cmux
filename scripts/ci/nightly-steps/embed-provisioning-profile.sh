#!/usr/bin/env bash
# Moved out of .github/workflows/nightly.yml (size cap); the step's env is unchanged.
if [ -z "$APP_PROVISIONING_PROFILE_BASE64" ]; then
  echo "Missing $PROFILE_SECRET_NAME secret" >&2
  exit 1
fi

APP_PATH="$CHANNEL_APP_PATH"
PROFILE_PATH="$APP_PATH/Contents/embedded.provisionprofile"
TMP_PROFILE="$(mktemp /tmp/cmux-channel-profile.XXXXXX)"
TMP_PLIST="$(mktemp /tmp/cmux-channel-profile.XXXXXX.plist)"
trap 'rm -f "$TMP_PROFILE" "$TMP_PLIST"' EXIT

echo "$APP_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$TMP_PROFILE"
security cms -D -i "$TMP_PROFILE" > "$TMP_PLIST"

APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP_PLIST")"
if [ "$APP_ID" != "7WLXT3NR37.${CHANNEL_BUNDLE_ID}" ]; then
  echo "$CHANNEL provisioning profile targets unexpected app ID: $APP_ID" >&2
  exit 1
fi

# The WebAuthn browser entitlement is an Apple-approved capability
# request. Nightly has it; the RC App ID's request has been pending
# since 2026-07-10, so cmux.rc.entitlements does not ask for it and
# RC ships without passkey sign-in in the embedded browser until Apple
# approves. The check follows the channel's entitlements file so the
# profile can never silently lag behind what the app requests.
if /usr/libexec/PlistBuddy -c "Print :com.apple.developer.web-browser.public-key-credential" "$CHANNEL_ENTITLEMENTS" >/dev/null 2>&1; then
  WEBAUTHN_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.web-browser.public-key-credential" "$TMP_PLIST" 2>/dev/null || true)"
  if [ "$WEBAUTHN_ENTITLEMENT" != "true" ]; then
    echo "$CHANNEL provisioning profile is missing WebAuthn browser entitlement" >&2
    exit 1
  fi
else
  echo "$CHANNEL entitlements do not request the WebAuthn browser entitlement; skipping the profile check"
fi

# Refuse an expired profile (an unparsable date is only reported).
EXPIRES="$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$TMP_PLIST" 2>/dev/null || true)"
EXPIRES_EPOCH="$(date -j -f '%a %b %d %T %Z %Y' "$EXPIRES" +%s 2>/dev/null || true)"
echo "$PROFILE_SECRET_NAME expires: ${EXPIRES:-unknown}"
if [ -n "$EXPIRES_EPOCH" ] && [ "$EXPIRES_EPOCH" -le "$(date +%s)" ]; then
  echo "$CHANNEL provisioning profile expired: $EXPIRES" >&2
  exit 1
fi

PROVISIONS_ALL_DEVICES="$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$TMP_PLIST")"
if [ "$PROVISIONS_ALL_DEVICES" != "true" ]; then
  echo "$CHANNEL provisioning profile is not a Developer ID all-devices profile" >&2
  exit 1
fi

cp "$TMP_PROFILE" "$PROFILE_PATH"
