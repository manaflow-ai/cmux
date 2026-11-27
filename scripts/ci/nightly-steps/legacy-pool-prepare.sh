#!/usr/bin/env bash
# nightly.yml legacy-signer-app: "Prepare the app as cmux NIGHTLY". The cmux NIGHTLY-identity copy of this
# run's prepared app for the release signer, as the macOS legacy signer makes it
# (legacy-identity-prepare-dmg.sh, then scripts/ci/nightly-next-legacy-identity.sh): the NEXT build's
# version, commit and Sparkle key with cmux NIGHTLY's name, bundle id, sign-in scheme and feed, the
# NIGHTLY Developer ID profile for that exact App ID, and the verified SSH daemon manifest.
# Runs in the build tree; TOOLS is the workflow commit's scripts.
set -euo pipefail
: "${TOOLS:?}" "${SIGNER_WORK:?}" "${NIGHTLY_BUILD:?}" "${NIGHTLY_MARKETING_VERSION:?}" "${BUILD_SHORT_SHA:?}"
: "${LEGACY_BUILD:?}" "${LEGACY_APPCAST:?}" "${NIGHTLY_NEXT_LEGACY_FEED_BASE:?}" "${NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY:?}"
[[ -n "${APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64:-}" ]] || { echo "Missing APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64 (release-next)" >&2; exit 1; }
# legacy-identity-target picked this run's own build (source_run), so the prepared app is that build.
[[ "$LEGACY_BUILD" == "$NIGHTLY_BUILD" ]] || { echo "the target build $LEGACY_BUILD is not this run's build $NIGHTLY_BUILD" >&2; exit 1; }
TEAM_ID=7WLXT3NR37
LEGACY_ID=com.cmuxterm.app.nightly
LEGACY_NAME="cmux NIGHTLY"

mkdir -p "$SIGNER_WORK"
tar -C "$SIGNER_WORK" -xzf prepared-app/cmux-prepared-app.tar.gz
[[ -d "$SIGNER_WORK/cmux.app/Contents" ]] || { echo "the prepared app has no cmux.app" >&2; exit 1; }
# A macOS tar stores extended attributes as ._ entries; a Mac folds them back, so they are no bundle files.
find "$SIGNER_WORK/cmux.app" -name '._*' -type f -delete
app="$SIGNER_WORK/$LEGACY_NAME.app"
rm -rf "$app"
mv "$SIGNER_WORK/cmux.app" "$app"

feed_url="${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
NIGHTLY_NEXT_FEED_BASE="$NIGHTLY_NEXT_LEGACY_FEED_BASE" python3 "$TOOLS/scripts/ci/nightly-next-guard.py" feed-url "$feed_url"
CHANNEL_APP_NAME="$LEGACY_NAME" CHANNEL_BUNDLE_ID="$LEGACY_ID" CHANNEL_URL_SCHEME=cmux-nightly FEED_URL="$feed_url" \
  SPARKLE_PUBLIC_KEY="$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" SHORT_SHA="$BUILD_SHORT_SHA" \
  python3 -I "$TOOLS/scripts/ci/release-signer/nightly_next_identity.py" --legacy "$app/Contents/Info.plist"

# The NIGHTLY Developer ID profile for this exact App ID (the release signer reconciles the app's
# entitlements with it: application-identifier and the access group the sign-in lives under).
profile="$app/Contents/embedded.provisionprofile"
(umask 022 && printf '%s' "$APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64" | base64 -d > "$profile") ||
  { echo "APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64 is not valid base64" >&2; exit 1; }
profile_plist="$(mktemp)"
openssl cms -verify -noverify -inform DER -in "$profile" -out "$profile_plist" 2>/dev/null ||
  { echo "the NIGHTLY profile is not a signed profile" >&2; exit 1; }
python3 -I - "$profile_plist" "$TEAM_ID.$LEGACY_ID" <<'PY'
import plistlib, sys
profile = plistlib.load(open(sys.argv[1], "rb"))
app_id = profile.get("Entitlements", {}).get("com.apple.application-identifier")
if app_id != sys.argv[2]:
    sys.exit(f"NIGHTLY profile targets {app_id}, not {sys.argv[2]}")
if profile.get("ProvisionsAllDevices") is not True:
    sys.exit("NIGHTLY profile is not Developer ID")
PY
rm -f "$profile_plist"

python3 scripts/verify_remote_daemon_release.py \
  --manifest "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
  --assets-dir remote-daemon-assets --app "$app" --embed
bash scripts/ci/verify-computer-use-helper.sh layout "$app"
echo "app=$app" >> "$GITHUB_OUTPUT"
