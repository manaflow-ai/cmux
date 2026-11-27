#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Sign the build as cmux NIGHTLY". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
[ -n "$APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64" ] || { echo "Missing APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64 (release-next)" >&2; exit 1; }
NIGHTLY_PROFILE_PATH="$RUNNER_TEMP/nightly.provisionprofile"
# Removed on every exit, a failed signature too: on an owned Mac nothing of a signing job stays on disk.
trap 'rm -f "$NIGHTLY_PROFILE_PATH"' EXIT
echo "$APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$NIGHTLY_PROFILE_PATH"
LEGACY_FEED_URL="${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
NIGHTLY_NEXT_FEED_BASE="$NIGHTLY_NEXT_LEGACY_FEED_BASE" python3 scripts/ci/nightly-next-guard.py feed-url "$LEGACY_FEED_URL"
NIGHTLY_PROFILE_PATH="$NIGHTLY_PROFILE_PATH" LEGACY_FEED_URL="$LEGACY_FEED_URL" \
  EXPECTED_SPARKLE_PUBLIC_KEY="$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" \
  ./scripts/ci/nightly-next-legacy-identity.sh \
    "next-in/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg" "$NIGHTLY_BUILD" legacy-app
rm -f "$NIGHTLY_PROFILE_PATH"
