#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly and nightly-next-one: "Inject nightly identities and metadata". Moved out of
# the workflow to keep nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: sets
# every input the run block read from ${{ }} expressions.
set -euo pipefail
SHORT_SHA="$BUILD_SHORT_SHA"
APP_DIR="build-universal/Build/Products/Release"

# The producer owns the version for both the daemon and every app variant.
: "${NIGHTLY_BUILD:?missing daemon build}" "${NIGHTLY_MARKETING_VERSION:?missing daemon version}"

NIGHTLY_DMG_IMMUTABLE="${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}.dmg"
NIGHTLY_DMG_RELEASE="${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.dmg"
# Thin variants get their own feed. The universal variant keeps the legacy
# feed name; the app's feed resolver rewrites it to the per-architecture
# feed at runtime, which is how older installs migrate.
if [ "$NIGHTLY_VARIANT" = "universal" ]; then
  NIGHTLY_APPCAST="appcast.xml"
else
  NIGHTLY_APPCAST="appcast-${NIGHTLY_VARIANT}.xml"
fi
{
  echo "NIGHTLY_BUILD=${NIGHTLY_BUILD}"
  echo "NIGHTLY_MARKETING_VERSION=${NIGHTLY_MARKETING_VERSION}"
  echo "NIGHTLY_DMG_IMMUTABLE=${NIGHTLY_DMG_IMMUTABLE}"
  echo "NIGHTLY_DMG_RELEASE=${NIGHTLY_DMG_RELEASE}"
  echo "NIGHTLY_APPCAST=${NIGHTLY_APPCAST}"
} >> "$GITHUB_ENV"

prepare_variant() {
  local app_dir="$1"
  local bundle_id="$2"
  local feed_url="$3"
  local app_plist="$app_dir/cmux.app/Contents/Info.plist"

  if [ "$TRACK" = "nightly-next" ]; then
    # NEXT owns update downloads in CmuxUpdater. Keep Sparkle's shared automatic-update
    # preference available to classic cmux while preventing SPUAutomaticUpdateDriver from
    # bypassing the app-owned policy when this bundle starts.
    /usr/libexec/PlistBuddy -c "Set :SUAllowsAutomaticUpdates false" "$app_plist"
    if [ "$(/usr/libexec/PlistBuddy -c "Print :SUAllowsAutomaticUpdates" "$app_plist")" != false ]; then
      echo "NEXT bundle must disable Sparkle automatic downloads" >&2
      exit 1
    fi
  fi

  /usr/libexec/PlistBuddy -c "Set :CFBundleName ${CHANNEL_APP_NAME}" "$app_plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${CHANNEL_APP_NAME}" "$app_plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_id}" "$app_plist"
  local url_type_name
  url_type_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:1:CFBundleURLName" "$app_plist")"
  if [[ "$url_type_name" != *.auth ]]; then
    echo "Expected CFBundleURLTypes[1] to be the auth URL type, found: $url_type_name" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 ${CHANNEL_URL_SCHEME}" "$app_plist"
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$app_plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$app_plist" >/dev/null 2>&1 || true
  if [ "$NOTARY_PROBE" = true ]; then
    # Production-identity probe: no key and no feed. Without
    # SUPublicEDKey the updater never starts and Sparkle accepts no
    # update, so this app can never update itself into any channel.
    if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app_plist" >/dev/null 2>&1; then
      echo "probe app still has SUPublicEDKey" >&2; exit 1
    fi
  else
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_KEY}" "$app_plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${feed_url}" "$app_plist"
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NIGHTLY_MARKETING_VERSION}" "$app_plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NIGHTLY_BUILD}" "$app_plist"
  /usr/libexec/PlistBuddy -c "Delete :CMUXCommit" "$app_plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CMUXCommit string ${SHORT_SHA}" "$app_plist"
  if [ "$CHANNEL_APP_NAME" != cmux ]; then
    mv "$app_dir/cmux.app" "$app_dir/${CHANNEL_APP_NAME}.app"
  fi
}

prepare_variant \
  "$APP_DIR" \
  "$CHANNEL_BUNDLE_ID" \
  "${CHANNEL_FEED_BASE}/${NIGHTLY_APPCAST}"
if [ "$TRACK" = "nightly-next" ] && [ "$NOTARY_PROBE" != true ]; then
  python3 scripts/ci/nightly-next-guard.py feed-url \
    "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_DIR/${CHANNEL_APP_NAME}.app/Contents/Info.plist")"
fi

echo "Channel: ${CHANNEL}"
echo "App name: ${CHANNEL_APP_NAME}"
echo "Variant: ${NIGHTLY_VARIANT}"
echo "Feed: ${CHANNEL_FEED_BASE}/${NIGHTLY_APPCAST}"
echo "Bundle ID: ${CHANNEL_BUNDLE_ID}"
echo "Marketing version: ${NIGHTLY_MARKETING_VERSION}"
echo "Build number: ${NIGHTLY_BUILD}"
echo "Immutable DMG: ${NIGHTLY_DMG_IMMUTABLE}"
echo "Commit SHA: ${SHORT_SHA}"
