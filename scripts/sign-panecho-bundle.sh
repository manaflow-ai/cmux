#!/usr/bin/env bash
# Inside-out codesign a Panecho .app bundle for Developer ID + notarization.
#
# Why this exists separately from scripts/sign-cmux-bundle.sh:
#   sign-cmux-bundle.sh hard-requires the com.apple.developer.web-browser.
#   public-key-credential entitlement post-sign. That entitlement is a
#   RESTRICTED capability requiring a managed provisioning profile. Under a
#   Developer ID signature with no profile, including it makes the app fail to
#   launch (verified: amfi "Launchd job spawn failed", errno 153). Panecho ships
#   without a provisioning profile, so it must omit that entitlement — and this
#   signer enforces that instead of requiring it.
#
# Usage:
#   scripts/sign-panecho-bundle.sh <app-path> <app-entitlements> <signing-identity>
#
# Example:
#   scripts/sign-panecho-bundle.sh \
#     "build-panecho/Build/Products/Release/Panecho.app" \
#     panecho.release.entitlements \
#     "Developer ID Application: Browserstack Inc (YQ5FZQ855D)"
#
# Optional env:
#   CMUX_HELPER_ENTITLEMENTS  (default: cmux-helper.entitlements)
#   CMUX_TIMESTAMP            set to "none" for un-timestamped local sigs
#
# Signs in Apple's inside-out order: CLI helpers -> plugins -> frameworks ->
# main bundle (no --deep on main, to preserve nested signatures).

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

[[ -d "$APP_PATH" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }
[[ -f "$APP_ENTITLEMENTS" ]] || { echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2; exit 1; }
[[ -f "$HELPER_ENTITLEMENTS" ]] || { echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2; exit 1; }

# Guard: Panecho Developer ID builds must not carry profile-bound / restricted
# entitlements, which break launch (errno 163/153) without a managed profile.
for forbidden in \
  "com.apple.developer.web-browser.public-key-credential" \
  "com.apple.application-identifier" \
  "com.apple.developer.team-identifier"; do
  if /usr/bin/plutil -extract "$forbidden" raw -o - "$APP_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "error: $APP_ENTITLEMENTS contains restricted entitlement '$forbidden'." >&2
    echo "       Developer ID (no provisioning profile) cannot launch with it." >&2
    exit 1
  fi
done

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
if [[ -x "$SCRIPT_DIR/verify-command-palette-nucleo-ffi-artifact.sh" ]]; then
  "$SCRIPT_DIR/verify-command-palette-nucleo-ffi-artifact.sh" "$APP_PATH"
fi

# Helpers must NOT carry the main app's restricted entitlements either.
for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  if /usr/bin/codesign -d --entitlements :- "$helper" 2>&1 | grep -q "application-identifier"; then
    echo "error: helper $(basename "$helper") unexpectedly carries application-identifier" >&2
    exit 1
  fi
done

echo "==> signing OK: $APP_PATH"
echo "    identity: $IDENTITY"
