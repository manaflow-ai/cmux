#!/usr/bin/env bash
# nightly.yml signer-app: "Prepare the app". The nightly-next identity and the
# SSH daemon manifest go into the prepared app before signing, as
# build-sign-notarize-nightly's "Restore prepared app", "Derive Sparkle public
# key", "Inject nightly identities and metadata" and "Embed verified SSH daemon
# manifest" do. Runs in the build tree; TOOLS is the workflow commit's scripts.
set -euo pipefail
: "${TOOLS:?}" "${SIGNER_WORK:?}" "${CHANNEL_APP_NAME:?}" "${NIGHTLY_BUILD:?}" "${NIGHTLY_MARKETING_VERSION:?}"
mkdir -p "$SIGNER_WORK"
tar -C "$SIGNER_WORK" -xzf prepared-app/cmux-prepared-app.tar.gz
[[ -d "$SIGNER_WORK/cmux.app/Contents" ]] || { echo "the prepared app has no cmux.app" >&2; exit 1; }
# A macOS tar stores extended attributes as ._ entries; a Mac folds them back,
# so they are no bundle files.
find "$SIGNER_WORK/cmux.app" -name '._*' -type f -delete

SPARKLE_PRIVATE_KEY="$(bash "$TOOLS/scripts/ci/nightly-sparkle-key.sh")"
export SPARKLE_PRIVATE_KEY
SPARKLE_PUBLIC_KEY="$(env -u NEXT_SPARKLE_PRIVATE_KEY python3 -I "$TOOLS/scripts/ci/dev_app_linux.py" sparkle-public-key SPARKLE_PRIVATE_KEY)"
unset SPARKLE_PRIVATE_KEY NEXT_SPARKLE_PRIVATE_KEY
[[ "$SPARKLE_PUBLIC_KEY" == "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" ]] ||
  { echo "SPARKLE_NEXT_PRIVATE_KEY does not derive the pinned NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" >&2; exit 1; }
echo "Derived Sparkle public key: $SPARKLE_PUBLIC_KEY"
export SPARKLE_PUBLIC_KEY SHORT_SHA="$BUILD_SHORT_SHA" FEED_URL="${CHANNEL_FEED_BASE}/appcast-${NIGHTLY_VARIANT}.xml"
python3 -I "$TOOLS/scripts/ci/release-signer/nightly_next_identity.py" "$SIGNER_WORK/cmux.app/Contents/Info.plist"
mv "$SIGNER_WORK/cmux.app" "$SIGNER_WORK/$CHANNEL_APP_NAME.app"
app="$SIGNER_WORK/$CHANNEL_APP_NAME.app"
python3 "$TOOLS/scripts/ci/nightly-next-guard.py" feed-url "$FEED_URL"

bundle_args=()
[[ "$BUNDLE_REMOTE_DAEMON_ASSETS" == true ]] && bundle_args+=(--bundle-assets)
python3 scripts/verify_remote_daemon_release.py \
  --manifest "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
  --assets-dir remote-daemon-assets --app "$app" --embed ${bundle_args[@]+"${bundle_args[@]}"}
bash scripts/ci/verify-computer-use-helper.sh layout "$app"
echo "app=$app" >> "$GITHUB_OUTPUT"
