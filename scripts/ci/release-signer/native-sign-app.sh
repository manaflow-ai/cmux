#!/usr/bin/env bash
# Sign a NEXT app with Apple's native codesign path on an owned Mac.
#
# The caller has already claimed the Mac and created the per-job keychain with
# signing-keychain.sh. This wrapper intentionally has no certificate import:
# credentials enter only through that keychain and are removed by the caller's
# always() cleanup step.
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "native-sign-app requires macOS" >&2; exit 2; }
[[ $# -eq 2 ]] || { echo "usage: $0 <app-path> <app-entitlements>" >&2; exit 2; }
APP_PATH="${1%/}"
APP_ENTITLEMENTS="$2"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN_BUNDLE_TOOL="${CMUX_SIGN_BUNDLE_TOOL:-$ROOT_DIR/sign-cmux-bundle.sh}"
HELPER_TOOL="${CMUX_HELPER_TOOL:-$ROOT_DIR/ci/notarize-computer-use-helper.sh}"
KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/ci/signing-keychain.sh}"
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is required}"
: "${ASC_API_KEY_ID:?ASC_API_KEY_ID is required}"
: "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID is required}"
: "${ASC_API_KEY_P8_BASE64:?ASC_API_KEY_P8_BASE64 is required}"
: "${CMUX_NATIVE_NOTARY_PROFILE:?CMUX_NATIVE_NOTARY_PROFILE is required}"
: "${CMUX_NATIVE_SIGNING_KEYCHAIN:?CMUX_NATIVE_SIGNING_KEYCHAIN is required}"

[[ -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }
[[ -f "$APP_ENTITLEMENTS" ]] || { echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2; exit 1; }

"$KEYCHAIN_TOOL" unlock
# Sign every nested component except the Computer Use helper first. The helper
# script signs, submits, staples and then re-seals only the outer app, which
# preserves its accepted ticket and the existing artifact contract.
CMUX_SIGN_MODE=all-except-computer-use \
  "$SIGN_BUNDLE_TOOL" "$APP_PATH" "$APP_ENTITLEMENTS" "$APPLE_SIGNING_IDENTITY"
CMUX_NOTARY_USE_KEYCHAIN_PROFILE=true \
  CMUX_SIGNING_KEYCHAIN_TOOL="$KEYCHAIN_TOOL" \
  "$HELPER_TOOL" "$APP_PATH" "$APP_ENTITLEMENTS" "$APPLE_SIGNING_IDENTITY"
