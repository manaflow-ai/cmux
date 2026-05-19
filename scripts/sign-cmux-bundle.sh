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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
"$SCRIPT_DIR/verify-command-palette-nucleo-ffi-artifact.sh" "$APP_PATH"

plist_print() {
  local plist_xml="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key_path" /dev/stdin <<<"$plist_xml" 2>/dev/null || true
}

plist_array_contains_exact() {
  local plist_xml="$1"
  local key_path="$2"
  local expected="$3"
  local index=0
  local value

  while value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}:${index}" /dev/stdin <<<"$plist_xml" 2>/dev/null)"; do
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

APP_ENTITLEMENTS_XML="$(plutil -convert xml1 -o - "$APP_ENTITLEMENTS")"
APP_ID="$(plist_print "$APP_ENTITLEMENTS_XML" "com.apple.application-identifier")"

SIGNED_ENTITLEMENTS="$(
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null \
    | plutil -convert xml1 -o - - 2>/dev/null
)"

if [[ -n "$APP_ID" ]]; then
  SIGNED_APP_ID="$(plist_print "$SIGNED_ENTITLEMENTS" "com.apple.application-identifier")"
  if [[ "$SIGNED_APP_ID" != "$APP_ID" ]]; then
    echo "error: signed app missing application-identifier $APP_ID" >&2
    exit 1
  fi
  KEYCHAIN_ACCESS_GROUPS="$(
    plist_print "$SIGNED_ENTITLEMENTS" "keychain-access-groups"
  )"
  if [[ -z "$KEYCHAIN_ACCESS_GROUPS" ]]; then
    echo "error: signed app missing keychain-access-groups entitlement" >&2
    exit 1
  fi
  if ! plist_array_contains_exact "$SIGNED_ENTITLEMENTS" "keychain-access-groups" "$APP_ID"; then
    echo "error: signed app missing keychain access group $APP_ID" >&2
    exit 1
  fi
fi
grep -Fq -- "com.apple.developer.web-browser.public-key-credential" <<<"$SIGNED_ENTITLEMENTS" || {
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
