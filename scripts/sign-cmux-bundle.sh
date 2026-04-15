#!/usr/bin/env bash
# Inside-out codesign a cmux .app bundle for Developer ID + notarization.
#
# Usage:
#   scripts/sign-cmux-bundle.sh <app-path> <app-entitlements> <signing-identity>
#
# Example:
#   scripts/sign-cmux-bundle.sh \
#     "build-universal/Build/Products/Release/cmux NIGHTLY.app" \
#     cmux.nightly.entitlements \
#     "Developer ID Application: Manaflow, Inc. (7WLXT3NR37)"
#
# Optional env:
#   CMUX_HELPER_ENTITLEMENTS  (default: cmux-helper.entitlements)
#   CMUX_TIMESTAMP             set to "none" for un-timestamped local sigs
#
# Signs in the Apple-documented inside-out order:
#   1. CLI helpers under Contents/Resources/bin/* with minimal
#      hardened-runtime entitlements (no application-identifier).
#   2. Each nested plugin under Contents/PlugIns/* with --deep.
#   3. Each nested framework under Contents/Frameworks/* with --deep
#      (covers Sparkle's XPCServices and Updater.app).
#   4. The main app bundle with the provided app-level entitlements,
#      WITHOUT --deep. --deep here would overwrite helper/plugin
#      signatures and re-introduce the app-id mismatch that amfi on
#      notarized macOS 26 Tahoe rejects with errno 163.

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <app-path> <app-entitlements> <signing-identity>" >&2
  exit 2
fi

APP_PATH="$1"
APP_ENTITLEMENTS="$2"
IDENTITY="$3"
HELPER_ENTITLEMENTS="${CMUX_HELPER_ENTITLEMENTS:-cmux-helper.entitlements}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2
  exit 1
fi
if [[ ! -f "$HELPER_ENTITLEMENTS" ]]; then
  echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2
  exit 1
fi

if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
  TS_FLAG=(--timestamp=none)
else
  TS_FLAG=(--timestamp)
fi

COMMON=(--force --options runtime "${TS_FLAG[@]}" --sign "$IDENTITY")

# 1. CLI helpers
for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  echo "==> signing helper $(basename "$helper")"
  /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
done

# 2. Plugins
if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do
    echo "==> signing plugin $(basename "$plugin")"
    /usr/bin/codesign "${COMMON[@]}" --deep "$plugin"
  done < <(find "$APP_PATH/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
fi

# 3. Frameworks
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    echo "==> signing framework $(basename "$framework")"
    /usr/bin/codesign "${COMMON[@]}" --deep "$framework"
  done < <(find "$APP_PATH/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi

# 4. Main app bundle (no --deep).
echo "==> signing main bundle"
/usr/bin/codesign "${COMMON[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

echo "==> verifying"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

APP_ID="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" \
  /dev/stdin <<<"$(plutil -convert xml1 -o - "$APP_ENTITLEMENTS")" 2>/dev/null || true)"

if [[ -n "$APP_ID" ]]; then
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 | grep -q "$APP_ID" || {
    echo "error: signed app missing application-identifier $APP_ID" >&2
    exit 1
  }
fi
/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 \
  | grep -q "com.apple.developer.web-browser.public-key-credential" || {
    echo "error: signed app missing web-browser entitlement" >&2
    exit 1
  }

# Helpers must NOT carry the main app's application-identifier.
for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  if /usr/bin/codesign -d --entitlements :- "$helper" 2>&1 \
       | grep -q "application-identifier"; then
    echo "error: helper $(basename "$helper") unexpectedly carries application-identifier" >&2
    exit 1
  fi
done

echo "==> signing OK: $APP_PATH"
