#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ios/scripts/upload-testflight.sh [--lane beta] [--build-number <number>]
                                  [--signing manual|automatic]
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
  --build-number <number>   CFBundleVersion. Defaults to UTC yyyyMMddHHmmss.
                            Self-healed up to (App Store Connect max + 1) if it
                            would not be the highest build (TestFlight only offers
                            the highest build as an update).
  --signing <mode>          Export signing mode: manual (default) or automatic.
                            manual uses the "Apple Distribution" certificate and
                            the "cmux Beta Distribution" provisioning profile from
                            the local keychain (for local/dev exports). automatic
                            uses Xcode cloud-managed signing via the ASC API key
                            and -allowProvisioningUpdates, so CI does not need an
                            iOS distribution cert/profile in the keychain.
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
# CFBundleVersion must increase monotonically or TestFlight won't offer the build
# as an update. Use a 14-digit UTC stamp (with seconds): earlier builds used
# yyyyMMddHHmmss (e.g. 20260520031606), and a 12-digit yyyyMMddHHmm (~2.0e11)
# is NUMERICALLY LOWER than those (~2.0e13), so it would regress below the
# existing max and never surface as an update. Keep seconds.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
# Whether BUILD_NUMBER was supplied by the caller (--build-number) rather than the
# UTC-timestamp default. The default is monotonic by construction, so it is safe
# to ship even if the App Store Connect lookup fails (fail-open). An explicit
# value carries no such guarantee, so if it can't be verified against ASC the
# guard fails CLOSED instead of shipping a possibly-stale build.
BUILD_NUMBER_EXPLICIT=0
ARCHIVE_PATH=""
EXPORT_ONLY=0
# Export signing mode. "manual" keeps the original local-keychain behavior;
# "automatic" switches the export to Xcode cloud-managed signing (used by CI,
# which has no iOS distribution cert/profile, only the ASC API key).
SIGNING="manual"

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
      BUILD_NUMBER_EXPLICIT=1
      shift 2
      ;;
    --signing)
      require_option_value "$1" "${2:-}"
      SIGNING="$2"
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

case "$SIGNING" in
  manual|automatic) ;;
  *)
    echo "error: unsupported signing mode '$SIGNING' (expected manual or automatic)" >&2
    usage >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$IOS_DIR/cmux.xcworkspace"
SCHEME="cmux-ios"
DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-7WLXT3NR37}"

# Resolve App Store Connect API auth (env, else local plist) BEFORE the
# monotonic guard and output-path computation below: the guard may finalize
# BUILD_NUMBER, and OUT_DIR is derived from BUILD_NUMBER.
LOCAL_ASC_CONFIG="$IOS_DIR/Config/AppStoreConnect.local.plist"
if [[ -f "$LOCAL_ASC_CONFIG" ]]; then
  ASC_API_KEY_ID="${ASC_API_KEY_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_ISSUER_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$(/usr/libexec/PlistBuddy -c 'Print :ASC_API_KEY_PATH' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
fi

# Monotonic build-number guard (defense in depth). TestFlight only offers a build
# as an *update* when its CFBundleVersion is the highest integer build for the
# app, so a regressed numbering scheme (or a bad manual --build-number) silently
# produces a build no tester can update to. Ask App Store Connect for the current
# max and never ship a number <= the existing max.
#
# Two cases:
#  - Fresh archive (the common path): BUILD_NUMBER is stamped at archive time, so
#    self-heal it up to (max + 1).
#  - Reused archive (--archive-path): the CFBundleVersion is already baked into
#    the archive and BUILD_NUMBER is never applied to it, so read the archive's
#    embedded version and FAIL (re-archive needed) rather than self-heal a value
#    that won't ship. EXPORT_ONLY exits before upload, so the guard is skipped.
#
# FAIL-OPEN on the *generated* path: any ASC/network/JWT error logs a warning and
# keeps the timestamp BUILD_NUMBER, because a transient API hiccup must never
# block a publish (the timestamp scheme is already correct; this is a backstop).
GUARD_BUILD_NUMBER="$BUILD_NUMBER"
GUARD_REUSED_ARCHIVE=0
# Set to 1 only once the build number that will ship is actually compared against
# the App Store Connect max. Anything that needs verification but reaches the
# upload without this set (a reused archive, or an explicit --build-number, on a
# path with no ASC API creds such as the Apple ID upload) is refused below, since
# it can't be renumbered or trusted.
GUARD_VERIFIED=0
RUN_GUARD=1
if [[ -n "$ARCHIVE_PATH" ]]; then
  # Reused archive: BUILD_NUMBER is never stamped into it, so the only number
  # that ships is the embedded CFBundleVersion, and it CANNOT be self-healed.
  # Such an archive must therefore be VERIFIABLE before an upload: if we cannot
  # read its version (below) or cannot reach App Store Connect (further down), we
  # fail CLOSED rather than upload a build that may not be offered as an update.
  # --export-only never uploads, so it only warns and skips.
  GUARD_REUSED_ARCHIVE=1
  # PlistBuddy prints "File Doesn't Exist..." to stdout (and exits non-zero) when
  # the archive or key is missing, so require a NUMERIC result rather than just
  # non-empty output; otherwise the error text would be mistaken for a version.
  ARCHIVE_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
  if [[ "$ARCHIVE_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    GUARD_BUILD_NUMBER="$ARCHIVE_BUILD_NUMBER"
  elif [[ "$EXPORT_ONLY" -eq 1 ]]; then
    echo "warning: --archive-path CFBundleVersion unreadable; skipping guard (--export-only, no upload)" >&2
    RUN_GUARD=0
  else
    echo "error: --archive-path given but could not read a numeric CFBundleVersion to verify monotonicity; refusing to upload an unverifiable archive. Re-archive with --build-number." >&2
    exit 1
  fi
fi

if [[ "$RUN_GUARD" -eq 1 && "$EXPORT_ONLY" -ne 1 && -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" && ( -n "${ASC_API_KEY_PATH:-}" || -n "${ASC_API_KEY_P8_BASE64:-}" ) ]]; then
  if ASC_MAX="$(ASC_API_KEY_ID="$ASC_API_KEY_ID" ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
      ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}" ASC_API_KEY_P8_BASE64="${ASC_API_KEY_P8_BASE64:-}" \
      python3 "$SCRIPT_DIR/asc_max_build.py" --bundle-id "$PRODUCT_BUNDLE_IDENTIFIER")"; then
    if [[ "$ASC_MAX" =~ ^[0-9]+$ && "$GUARD_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
      # A real numeric comparison happened: the shipping build number is verified.
      GUARD_VERIFIED=1
      if (( 10#$GUARD_BUILD_NUMBER <= 10#$ASC_MAX )); then
        if [[ "$GUARD_REUSED_ARCHIVE" -eq 1 ]]; then
          echo "error: reused archive CFBundleVersion $GUARD_BUILD_NUMBER <= App Store Connect max $ASC_MAX; TestFlight will not offer it as an update. Re-archive with a higher --build-number." >&2
          exit 1
        fi
        if [[ "$BUILD_NUMBER_EXPLICIT" -eq 1 ]]; then
          echo "error: explicit --build-number $GUARD_BUILD_NUMBER <= App Store Connect max $ASC_MAX; TestFlight will not offer it as an update. Use a higher number, or omit --build-number to use a monotonic UTC timestamp." >&2
          exit 1
        fi
        # Generated timestamp below the max (only via clock skew): self-heal it.
        NEXT_BUILD=$((10#$ASC_MAX + 1))
        echo "warning: generated build number $GUARD_BUILD_NUMBER <= App Store Connect max $ASC_MAX; bumping to $NEXT_BUILD to keep CFBundleVersion monotonic" >&2
        BUILD_NUMBER="$NEXT_BUILD"
      else
        echo "build-number guard: $GUARD_BUILD_NUMBER > App Store Connect max $ASC_MAX, keeping it" >&2
      fi
    else
      # Non-numeric ASC max or build number: no comparison possible. Leave
      # GUARD_VERIFIED unset; the fail-closed gate below handles reused/explicit.
      echo "warning: build-number guard could not compare $GUARD_BUILD_NUMBER against App Store Connect max ${ASC_MAX:-?}; leaving it unverified" >&2
    fi
  else
    echo "warning: build-number guard could not read the App Store Connect max; leaving $GUARD_BUILD_NUMBER unverified" >&2
  fi
fi

# Fail-closed gate, before the (expensive) archive. A build that needs
# verification but was not actually compared against the App Store Connect max
# (ASC unreachable, no ASC API creds such as the Apple ID upload path, or a
# non-numeric value) is refused here. A reused --archive-path can't be
# renumbered; an explicit --build-number may be stale. The generated UTC
# timestamp is monotonic by construction, so it is exempt (fail-open).
# --export-only never uploads, so it is exempt too.
if [[ "$EXPORT_ONLY" -ne 1 && "$GUARD_VERIFIED" -ne 1 ]]; then
  if [[ "$GUARD_REUSED_ARCHIVE" -eq 1 ]]; then
    echo "error: refusing to upload a reused --archive-path that was not verified monotonic against App Store Connect. Re-archive with --build-number, or provide ASC_API_KEY_ID/ASC_API_ISSUER_ID/ASC_API_KEY_PATH so it can be checked." >&2
    exit 1
  fi
  if [[ "$BUILD_NUMBER_EXPLICIT" -eq 1 ]]; then
    echo "error: refusing to upload an explicit --build-number $BUILD_NUMBER that was not verified monotonic against App Store Connect (it may be stale). Omit --build-number to use a monotonic UTC timestamp, or provide ASC_API_KEY_ID/ASC_API_ISSUER_ID/ASC_API_KEY_PATH so it can be checked." >&2
    exit 1
  fi
fi

# Expose the CFBundleVersion that will actually ship so a CI summary or caller
# reports the post-guard value (the guard may have bumped a fresh build). For a
# reused --archive-path the shipping version is the archive's embedded one, not
# BUILD_NUMBER (which is never applied to it).
SHIPPED_BUILD_NUMBER="$BUILD_NUMBER"
if [[ "$GUARD_REUSED_ARCHIVE" -eq 1 && "${ARCHIVE_BUILD_NUMBER:-}" =~ ^[0-9]+$ ]]; then
  SHIPPED_BUILD_NUMBER="$ARCHIVE_BUILD_NUMBER"
fi
if [[ -n "${CMUX_BUILD_NUMBER_OUT_FILE:-}" ]]; then
  printf '%s\n' "$SHIPPED_BUILD_NUMBER" > "$CMUX_BUILD_NUMBER_OUT_FILE"
fi

OUT_DIR="${CMUX_IOS_UPLOAD_DIR:-/tmp/cmux-ios-testflight-$BUILD_NUMBER}"
DERIVED_DATA="$OUT_DIR/DerivedData"
EXPORT_PATH="$OUT_DIR/export"
EXPORT_OPTIONS="$OUT_DIR/ExportOptions.plist"

mkdir -p "$OUT_DIR"

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
  # Archive WITHOUT signing. The export step below does all signing (manual cert
  # or automatic cloud distribution). Signing the archive with automatic +
  # -allowProvisioningUpdates makes Xcode mint a NEW Apple Development cert on
  # every ephemeral CI runner, which exhausts the account's certificate cap and
  # then fails ("maximum number of certificates" / "no profiles found"). An
  # unsigned archive creates no certs; the reused (cloud-managed) distribution
  # cert is applied only at export, where it does not churn.
  xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    PRODUCT_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
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
# Keys common to both signing modes.
plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
plutil -insert destination -string export "$EXPORT_OPTIONS"
plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS"
plutil -insert testFlightInternalTestingOnly -bool YES "$EXPORT_OPTIONS"
plutil -insert uploadSymbols -bool YES "$EXPORT_OPTIONS"
if [[ "$SIGNING" == "automatic" ]]; then
  # Cloud-managed signing: Xcode mints the distribution cert/profile on demand
  # via the ASC API key + -allowProvisioningUpdates (already passed below), so
  # the runner needs no iOS distribution cert/profile in its keychain. The
  # signingCertificate/provisioningProfiles keys must be omitted in this mode;
  # naming a profile that isn't installed makes -exportArchive fail.
  plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
else
  # Manual signing: requires the "Apple Distribution" certificate and the named
  # provisioning profile to already be present in the local keychain.
  plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
  plutil -insert signingCertificate -string "Apple Distribution" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$PRODUCT_BUNDLE_IDENTIFIER string $PROVISIONING_PROFILE_NAME" "$EXPORT_OPTIONS"
fi

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
