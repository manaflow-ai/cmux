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
#   3. CEF dylibs/frameworks/helper apps with Chromium JIT entitlements.
#   4. Each remaining nested framework under Contents/Frameworks/* with --deep
#      (covers Sparkle's XPCServices and Updater.app).
#   5. The main app bundle with the provided app-level entitlements,
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
FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"

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

# 3. CEF runtime
if [[ -d "$FRAMEWORKS_PATH/Chromium Embedded Framework.framework" ]]; then
  find "$FRAMEWORKS_PATH/Chromium Embedded Framework.framework/Libraries" \
    -name '*.dylib' \
    -type f \
    -print0 2>/dev/null |
    while IFS= read -r -d '' dylib_path; do
      echo "==> signing CEF dylib $(basename "$dylib_path")"
      /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$dylib_path"
    done

  echo "==> signing CEF framework"
  /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$FRAMEWORKS_PATH/Chromium Embedded Framework.framework"

  find "$FRAMEWORKS_PATH" \
    -mindepth 1 \
    -maxdepth 1 \
    -name 'cmux Helper*.app' \
    -type d \
    -print0 |
    while IFS= read -r -d '' helper_app; do
      helper_name="$(basename "$helper_app" .app)"
      helper_executable="$helper_app/Contents/MacOS/$helper_name"
      if [[ -x "$helper_executable" ]]; then
        echo "==> signing CEF helper executable $helper_name"
        /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper_executable"
      fi
      echo "==> signing CEF helper app $helper_name"
      /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper_app"
    done
fi

# 4. Frameworks
if [[ -d "$FRAMEWORKS_PATH" ]]; then
  while IFS= read -r -d '' framework; do
    case "$(basename "$framework")" in
      "Chromium Embedded Framework.framework"|cmux\ Helper*.app)
        continue
        ;;
    esac
    echo "==> signing framework $(basename "$framework")"
    /usr/bin/codesign "${COMMON[@]}" --deep "$framework"
  done < <(find "$FRAMEWORKS_PATH" -mindepth 1 -maxdepth 1 -print0)
fi

# 5. Main app bundle (no --deep).
echo "==> signing main bundle"
/usr/bin/codesign "${COMMON[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

echo "==> verifying"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$SCRIPT_DIR/verify-command-palette-nucleo-ffi-artifact.sh" "$APP_PATH"

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
while IFS= read -r -d '' helper_app; do
  helper_name="$(basename "$helper_app" .app)"
  helper_executable="$helper_app/Contents/MacOS/$helper_name"
  [[ -f "$helper_executable" && -x "$helper_executable" ]] || continue
  if /usr/bin/codesign -d --entitlements :- "$helper_executable" 2>&1 \
       | grep -q "application-identifier"; then
    echo "error: CEF helper $helper_name unexpectedly carries application-identifier" >&2
    exit 1
  fi
done < <(find "$FRAMEWORKS_PATH" -maxdepth 1 -type d -name "cmux Helper*.app" -print0 2>/dev/null || true)

echo "==> signing OK: $APP_PATH"
