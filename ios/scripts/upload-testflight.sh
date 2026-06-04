#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ios/scripts/upload-testflight.sh [--lane beta] [--build-number <number>]
                                  [--archive-path <path>] [--export-only]

Archives cmux iOS, exports an App Store Connect IPA, and uploads it to
TestFlight. The default lane is beta:

  bundle id: dev.cmux.app.beta
  profile:   cmux Beta Distribution

Authentication uses one of:

  ASC_API_KEY_ID
  ASC_API_ISSUER_ID
  ASC_API_KEY_PATH

or a local plist at:

  ios/Config/AppStoreConnect.local.plist

with string keys:

  ASC_API_KEY_ID
  ASC_API_ISSUER_ID
  ASC_API_KEY_PATH

or:

  APPLE_ID
  APPLE_APP_SPECIFIC_PASSWORD
  APPLE_PROVIDER_PUBLIC_ID

Options:
  --lane <beta>             Distribution lane. Only beta is currently defined.
  --build-number <number>   CFBundleVersion. Defaults to UTC yyyyMMddHHmm.
  --archive-path <path>     Reuse an existing archive instead of archiving.
  --export-only             Stop after exporting the signed IPA.
  -h, --help                Show this help.
EOF
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "error: missing value for $option" >&2
    usage >&2
    exit 2
  fi
}

LANE="beta"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
ARCHIVE_PATH=""
EXPORT_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)
      require_option_value "$1" "${2:-}"
      LANE="$2"
      shift 2
      ;;
    --build-number)
      require_option_value "$1" "${2:-}"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --archive-path)
      require_option_value "$1" "${2:-}"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --export-only)
      EXPORT_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unexpected argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$LANE" in
  beta)
    PRODUCT_BUNDLE_IDENTIFIER="dev.cmux.app.beta"
    PROVISIONING_PROFILE_NAME="${IOS_BETA_PROVISIONING_PROFILE_NAME:-cmux Beta Distribution}"
    ;;
  *)
    echo "error: unsupported lane '$LANE'" >&2
    usage >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$IOS_DIR/cmux.xcworkspace"
SCHEME="cmux-ios"
DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-7WLXT3NR37}"
OUT_DIR="${CMUX_IOS_UPLOAD_DIR:-/tmp/cmux-ios-testflight-$BUILD_NUMBER}"
DERIVED_DATA="$OUT_DIR/DerivedData"
EXPORT_PATH="$OUT_DIR/export"
EXPORT_OPTIONS="$OUT_DIR/ExportOptions.plist"

mkdir -p "$OUT_DIR"

LOCAL_ASC_CONFIG="$IOS_DIR/Config/AppStoreConnect.local.plist"
if [[ -f "$LOCAL_ASC_CONFIG" ]]; then
  ASC_API_KEY_ID="${ASC_API_KEY_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_ISSUER_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_PATH' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
fi

XCODE_AUTH_ARGS=()
if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" && -n "${ASC_API_KEY_PATH:-}" ]]; then
  XCODE_AUTH_ARGS=(
    -authenticationKeyPath "$ASC_API_KEY_PATH"
    -authenticationKeyID "$ASC_API_KEY_ID"
    -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
  )
fi

if [[ -z "$ARCHIVE_PATH" ]]; then
  ARCHIVE_PATH="$OUT_DIR/cmux.xcarchive"
  xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    PRODUCT_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Automatic \
    "${XCODE_AUTH_ARGS[@]}" \
    | tee "$OUT_DIR/archive.log"
else
  if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "error: archive not found: $ARCHIVE_PATH" >&2
    exit 1
  fi
fi

rm -rf "$EXPORT_PATH"
mkdir -p "$EXPORT_PATH"
rm -f "$EXPORT_OPTIONS"
touch "$EXPORT_OPTIONS"
plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
plutil -insert destination -string export "$EXPORT_OPTIONS"
plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS"
plutil -insert testFlightInternalTestingOnly -bool YES "$EXPORT_OPTIONS"
plutil -insert uploadSymbols -bool YES "$EXPORT_OPTIONS"
plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
plutil -insert signingCertificate -string "Apple Distribution" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$PRODUCT_BUNDLE_IDENTIFIER string $PROVISIONING_PROFILE_NAME" "$EXPORT_OPTIONS"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH_ARGS[@]}" \
  | tee "$OUT_DIR/export.log"

IPA_PATH="$EXPORT_PATH/cmux.ipa"
if [[ ! -f "$IPA_PATH" ]]; then
  echo "error: IPA was not exported at $IPA_PATH" >&2
  exit 1
fi

echo "IPA_PATH=$IPA_PATH"

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  exit 0
fi

if [[ -n "${ASC_API_KEY_ID:-}" || -n "${ASC_API_ISSUER_ID:-}" || -n "${ASC_API_KEY_PATH:-}" ]]; then
  if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" || -z "${ASC_API_KEY_PATH:-}" ]]; then
    echo "error: ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH must be set together" >&2
    exit 2
  fi
  if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
    echo "error: ASC_API_KEY_PATH does not exist: $ASC_API_KEY_PATH" >&2
    exit 2
  fi

  API_KEY_DIR="$OUT_DIR/private_keys"
  mkdir -p "$API_KEY_DIR"
  ln -sf "$ASC_API_KEY_PATH" "$API_KEY_DIR/AuthKey_$ASC_API_KEY_ID.p8"

  API_PRIVATE_KEYS_DIR="$API_KEY_DIR" xcrun altool --upload-app \
    --type ios \
    --file "$IPA_PATH" \
    --api-key "$ASC_API_KEY_ID" \
    --api-issuer "$ASC_API_ISSUER_ID" \
    | tee "$OUT_DIR/upload.log"
elif [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -n "${APPLE_PROVIDER_PUBLIC_ID:-}" ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -z "${APPLE_PROVIDER_PUBLIC_ID:-}" ]]; then
    echo "error: APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_PROVIDER_PUBLIC_ID must be set together" >&2
    exit 2
  fi

  xcrun altool --upload-app \
    --type ios \
    --file "$IPA_PATH" \
    --username "$APPLE_ID" \
    --app-password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --provider-public-id "$APPLE_PROVIDER_PUBLIC_ID" \
    | tee "$OUT_DIR/upload.log"
else
  cat >&2 <<EOF
error: missing TestFlight upload credentials.

Set ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH, or set
APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_PROVIDER_PUBLIC_ID. You can
also create ios/Config/AppStoreConnect.local.plist with the ASC_* keys.
EOF
  exit 2
fi
