#!/usr/bin/env bash
set -euo pipefail

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

# Verify a built/exported IPA's single .app is strictly signed AND carries
# aps-environment == "production" in its actual code signature. A config-level
# entitlement only delivers push if it survives into the SIGNED binary; only
# `codesign -d --entitlements` on the .app proves it (see the #5496 regression
# note below). The VALUE matters, not just presence: a "development" value
# registers a sandbox token that the production APNs host (which TestFlight runs
# against) rejects with BadDeviceToken, which is the exact failure this guards.
# Returns 0 only when production push is genuinely wired; non-zero otherwise.
# One shared check used by both signing paths (manual post-re-sign gate,
# automatic pre-upload gate) so the two paths can't drift.
verify_ipa_aps_environment_production() {
  local ipa="$1"
  local workdir app ent aps apple_sign_in
  workdir="$(mktemp -d)"
  if ! ( cd "$workdir" && unzip -q "$ipa" ); then
    echo "error: could not unzip IPA to verify entitlements: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi
  app="$(find "$workdir/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "error: IPA has no Payload/*.app to verify: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi
  # --verify --strict catches a corrupt bundle (e.g. a bad re-zip).
  if ! codesign --verify --strict --verbose=2 "$app" >&2; then
    rm -rf "$workdir"
    return 1
  fi
  # Read the signed entitlements and assert aps-environment == production.
  ent="$workdir/signed-entitlements.plist"
  if ! codesign -d --entitlements :- --xml "$app" > "$ent" 2>/dev/null; then
    echo "error: could not read entitlements from signed app: $app" >&2
    rm -rf "$workdir"
    return 1
  fi
  # PlistBuddy exits non-zero when a key is absent; tolerate that read and then
  # require exact entitlement values so the error explains the missing capability.
  aps="$("$PLISTBUDDY" -c 'Print :aps-environment' "$ent" 2>/dev/null || true)"
  if [[ "$aps" != "production" ]]; then
    echo "error: signed app aps-environment is '${aps:-<absent>}', expected 'production' (push would silently fail): $app" >&2
    plutil -p "$ent" >&2 || true
    rm -rf "$workdir"
    return 1
  fi
  apple_sign_in="$("$PLISTBUDDY" -c 'Print :com.apple.developer.applesignin:0' "$ent" 2>/dev/null || true)"
  if [[ "$apple_sign_in" != "Default" ]]; then
    echo "error: signed app com.apple.developer.applesignin is '${apple_sign_in:-<absent>}', expected 'Default' (Sign in with Apple would fail): $app" >&2
    plutil -p "$ent" >&2 || true
    rm -rf "$workdir"
    return 1
  fi
  rm -rf "$workdir"
  return 0
}

verify_ipa_bundle_identity() {
  local ipa="$1"
  local expected_bundle_id="$2"
  local team_id="$3"
  local expected_crash_reporting="${4:-}"
  local expected_app_id="$team_id.$expected_bundle_id"
  local workdir app plist_bundle_id plist_crash_reporting profile_plist profile_app_id ent ent_app_id

  workdir="$(mktemp -d)"
  if ! ( cd "$workdir" && unzip -q "$ipa" ); then
    echo "error: could not unzip IPA to verify bundle identity: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi
  app="$(find "$workdir/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "error: IPA has no Payload/*.app to verify bundle identity: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi

  plist_bundle_id="$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null || true)"
  if [[ "$plist_bundle_id" != "$expected_bundle_id" ]]; then
    echo "error: signed IPA CFBundleIdentifier is '${plist_bundle_id:-<absent>}', expected '$expected_bundle_id': $app" >&2
    rm -rf "$workdir"
    return 1
  fi
  if [[ -n "$expected_crash_reporting" ]]; then
    plist_crash_reporting="$("$PLISTBUDDY" -c 'Print :CMUXCrashReportingEnabled' "$app/Info.plist" 2>/dev/null || true)"
    if [[ "$plist_crash_reporting" != "$expected_crash_reporting" ]]; then
      echo "error: signed IPA CMUXCrashReportingEnabled is '${plist_crash_reporting:-<absent>}', expected '$expected_crash_reporting': $app" >&2
      rm -rf "$workdir"
      return 1
    fi
  fi

  profile_plist="$workdir/profile.plist"
  if ! security cms -D -i "$app/embedded.mobileprovision" > "$profile_plist"; then
    echo "error: could not decode embedded.mobileprovision from signed IPA: $app" >&2
    rm -rf "$workdir"
    return 1
  fi
  profile_app_id="$("$PLISTBUDDY" -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
  if [[ "$profile_app_id" != "$expected_app_id" ]]; then
    echo "error: signed IPA provisioning profile application-identifier is '${profile_app_id:-<absent>}', expected '$expected_app_id': $app" >&2
    rm -rf "$workdir"
    return 1
  fi

  ent="$workdir/signed-entitlements.plist"
  if ! codesign -d --entitlements :- --xml "$app" > "$ent" 2>/dev/null; then
    echo "error: could not read signed IPA entitlements: $app" >&2
    rm -rf "$workdir"
    return 1
  fi
  ent_app_id="$("$PLISTBUDDY" -c 'Print :application-identifier' "$ent" 2>/dev/null || true)"
  if [[ "$ent_app_id" != "$expected_app_id" ]]; then
    echo "error: signed IPA entitlement application-identifier is '${ent_app_id:-<absent>}', expected '$expected_app_id': $app" >&2
    plutil -p "$ent" >&2 || true
    rm -rf "$workdir"
    return 1
  fi

  rm -rf "$workdir"
  return 0
}

# App Store Connect rejects embedded iOS frameworks whose bundle metadata omits
# MinimumOSVersion (90530/90360). Validate the final IPA, after export and any
# re-sign, so a malformed binary Swift package fails here with its framework
# name instead of after a slow upload.
verify_ipa_framework_minimum_os_versions() {
  local ipa="$1"
  local workdir app framework plist minimum framework_name major

  workdir="$(mktemp -d)"
  if ! ( cd "$workdir" && unzip -q "$ipa" ); then
    echo "error: could not unzip IPA to verify framework metadata: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi
  app="$(find "$workdir/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "error: IPA has no Payload/*.app to verify framework metadata: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi

  while IFS= read -r -d '' framework; do
    framework_name="$(basename "$framework")"
    # ASC validates the framework BINARY, not just Info.plist: an embedded
    # framework whose executable is a static archive, a stripped-out shell
    # (Info.plist with no binary — Xcode's export processing leaves these
    # behind for static SPM binaryTargets), or any other non-dylib blob is
    # rejected in processing (ITMS-90208) even when its Info.plist declares
    # MinimumOSVersion. The manual re-sign path strips those, so reaching
    # this check with one still embedded is a hard error: an embedded
    # framework must be a dynamically linked Mach-O, full stop.
    framework_exec_name="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$framework/Info.plist" 2>/dev/null || basename "$framework" .framework)"
    framework_binary="$framework/$framework_exec_name"
    if [[ ! -f "$framework_binary" ]]; then
      echo "error: $framework_name is embedded in the app bundle but has no executable ($framework_exec_name); ASC rejects invalid framework shells (ITMS-90208). Strip it from Frameworks/." >&2
      rm -rf "$workdir"
      return 1
    fi
    if ! file -b "$framework_binary" | grep -q 'dynamically linked shared library'; then
      echo "error: $framework_name is embedded in the app bundle but its executable is not a dynamic library ($(file -b "$framework_binary")); ASC rejects this (ITMS-90208). Strip it from Frameworks/ (static code is already linked into the app executable)." >&2
      rm -rf "$workdir"
      return 1
    fi
    plist="$framework/Info.plist"
    if [[ ! -f "$plist" ]]; then
      echo "error: $framework_name is missing Info.plist" >&2
      rm -rf "$workdir"
      return 1
    fi
    minimum="$("$PLISTBUDDY" -c 'Print :MinimumOSVersion' "$plist" 2>/dev/null || true)"
    if [[ -z "$minimum" ]]; then
      echo "error: $framework_name is missing MinimumOSVersion" >&2
      rm -rf "$workdir"
      return 1
    fi
    if [[ ! "$minimum" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
      echo "error: $framework_name has invalid MinimumOSVersion '$minimum'" >&2
      rm -rf "$workdir"
      return 1
    fi
    major="${minimum%%.*}"
    if (( major < 8 )); then
      echo "error: $framework_name MinimumOSVersion '$minimum' must be 8.0 or later" >&2
      rm -rf "$workdir"
      return 1
    fi
    # The plist must not claim a LOWER minimum than the binary actually
    # supports: ASC rejects that internal inconsistency as ITMS-90208 ("the
    # bundle does not support the minimum OS Version specified in the
    # Info.plist"). This is exactly how Xcode-synthesized dylibs for static
    # SPM binaryTargets shipped broken (binary minos = app deployment target,
    # plist copied from the xcframework).
    binary_minos="$(xcrun vtool -show-build "$framework_binary" 2>/dev/null | awk '/^ *minos /{print $2; exit}')"
    if [[ -n "$binary_minos" && "$binary_minos" != "$minimum" ]]; then
      lowest="$(printf '%s\n%s\n' "$minimum" "$binary_minos" | sort -V | head -n 1)"
      if [[ "$lowest" == "$minimum" ]]; then
        echo "error: $framework_name Info.plist MinimumOSVersion '$minimum' is lower than its binary's minos '$binary_minos'; ASC rejects this (ITMS-90208)" >&2
        rm -rf "$workdir"
        return 1
      fi
    fi
  done < <(find "$app" -type d -name '*.framework' -print0)

  rm -rf "$workdir"
  return 0
}

verify_app_store_ipa_has_no_external_purchase_links() {
  local ipa="$1"
  local workdir app matches
  workdir="$(mktemp -d)"
  if ! ( cd "$workdir" && unzip -q "$ipa" ); then
    echo "error: could not unzip IPA to verify App Store review links: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi
  app="$(find "$workdir/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "error: IPA has no Payload/*.app to verify App Store review links: $ipa" >&2
    rm -rf "$workdir"
    return 1
  fi

  matches="$(LC_ALL=C grep -R -a -l -E 'github\.com/manaflow-ai/cmux#founders-edition|founders-edition' "$app" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "error: App Store IPA contains an external Founders Edition purchase/enrollment link; refusing to upload" >&2
    printf '%s\n' "$matches" >&2
    rm -rf "$workdir"
    return 1
  fi

  rm -rf "$workdir"
  return 0
}

usage() {
  cat <<'EOF'
Usage:
  ios/scripts/upload-testflight.sh [--lane beta|appstore] [--build-number <number>]
                                  [--signing manual|automatic] [--external]
                                  [--archive-path <path>] [--export-only]

Archives cmux iOS, exports an App Store Connect IPA, and uploads it to
App Store Connect. The default lane is beta and preserves the existing
TestFlight behavior:

  bundle id: dev.cmux.app.beta
  profile:   cmux Beta Distribution

The production App Store lane uses:

  bundle id: com.cmux.app
  profile:   cmux App Store Distribution
  display:   cmux

On the manual signing path the exported app is RE-SIGNED with the full
entitlements before upload. The archive is built unsigned (to avoid
distribution-cert churn), so -exportArchive re-adds only the profile baseline
and silently DROPS app-capability entitlements like aps-environment. That is
the https://github.com/manaflow-ai/cmux/pull/5496 regression that killed
beta/prod push. A config-level entitlements file alone does not prove the
entitlement reaches the signed binary; only codesign -d --entitlements on the
exported app does. So the re-sign merges Config/cmux-release.entitlements into
the export baseline and signs with the local distribution cert, gated on
codesign showing aps-environment and a strict signature verify.

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

With ASC API authentication, the appstore lane also requires ASC_APP_ID and the
asc CLI so upload can target the numeric App Store Connect app record instead
of relying on bundle-id lookup. Apple ID credentials keep using altool.

Options:
  --lane <beta|appstore>    Distribution lane. beta is the existing TestFlight
                            path. appstore uploads the production App Store
                            build and skips TestFlight notes/group assignment.
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
  --external                Make the build eligible for EXTERNAL TestFlight
                            testers (sets testFlightInternalTestingOnly=NO).
                            Default is internal-only: builds reach internal
                            groups (e.g. "cmux beta") instantly but can never
                            be added to an external group. External-eligible
                            builds must pass Apple Beta App Review (~24h) before
                            external testers can install the first build of a new
                            MARKETING_VERSION. With ASC API-key auth, the script
                            also assigns the processed build to the selected
                            external beta group (single external group by
                            default, or CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID / _NAME)
                            and auto-submits a new MARKETING_VERSION for Beta App
                            Review when Apple reports READY_FOR_BETA_SUBMISSION.
                            Also set via
                            CMUX_TESTFLIGHT_EXTERNAL=1.
  --archive-path <path>     Reuse an existing archive instead of archiving.
  --export-only             Stop after exporting the signed IPA.
  --skip-notes              Do not set the TestFlight "What to Test" notes after
                            upload. By default a successful upload pushes the top
                            ios/CHANGELOG.md entry to the build (the Internal block,
                            or the External block with --external). Also via
                            CMUX_TESTFLIGHT_SKIP_NOTES=1.
  --notes-from-range <base> Auto-generate the "What to Test" notes from the
                            iOS-affecting commits in <base>..HEAD instead of the
                            ios/CHANGELOG.md top entry (used by the every-2h beta
                            lane so each build's notes reflect what changed since
                            the previous beta for the selected audience). Skips
                            the changelog preflight and version-match guard.
  --auto-version            Stamp the beta build's MARKETING_VERSION at archive time
                            (no repo commit) to the next patch above the last
                            iOS release (newest ios-v<X.Y.Z> tag, else the
                            checked-in beta marketing version), so betas show
                            e.g. 1.0.4 while 1.0.3 is the last release. Implies
                            range-notes mode (skips the changelog preflight and
                            version-match guard, since the stamped version
                            deliberately will not match the changelog top); when
                            no --notes-from-range base is given the generator
                            emits its fallback line.
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

read_xcconfig_setting() {
  local key="$1"
  local file="$2"
  sed -nE "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\\1/p" "$file" 2>/dev/null | tail -n 1
}

require_marketing_version() {
  local label="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: $label marketing version must be X.Y or X.Y.Z (got '${value:-}')" >&2
    exit 2
  fi
}

version_gt() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch
  [[ "$left" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || return 1
  [[ "$right" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || return 0
  IFS='.' read -r left_major left_minor left_patch <<< "$left"
  IFS='.' read -r right_major right_minor right_patch <<< "$right"
  left_patch="${left_patch:-0}"
  right_patch="${right_patch:-0}"
  if (( 10#$left_major != 10#$right_major )); then
    (( 10#$left_major > 10#$right_major ))
    return
  fi
  if (( 10#$left_minor != 10#$right_minor )); then
    (( 10#$left_minor > 10#$right_minor ))
    return
  fi
  (( 10#$left_patch > 10#$right_patch ))
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
# Whether the exported build is eligible for external TestFlight testers.
# Default 0 keeps the historical internal-only behavior (fast dogfood, no Apple
# review). Set to 1 by --external or CMUX_TESTFLIGHT_EXTERNAL=1 to drop the
# testFlightInternalTestingOnly flag so the build can be added to an external
# group; such builds then require a one-time Apple Beta App Review per beta
# marketing version.
EXTERNAL_TESTING=0
if [[ "${CMUX_TESTFLIGHT_EXTERNAL:-}" == "1" ]]; then
  EXTERNAL_TESTING=1
fi
# Whether this invocation should assign an uploaded external build to the
# external beta group itself. The scheduled GitHub Actions lane disables this and
# runs assignment in a separate post-upload job so a distribution failure cannot
# cause duplicate uploads of the same SHA on the next schedule.
ASSIGN_EXTERNAL_GROUP=1
if [[ "${CMUX_TESTFLIGHT_ASSIGN_EXTERNAL_GROUP:-1}" == "0" ]]; then
  ASSIGN_EXTERNAL_GROUP=0
fi
# After a successful upload, push the top ios/CHANGELOG.md entry to the build's
# TestFlight "What to Test" so testers see what changed instead of an opaque
# timestamp. Set to 1 by --skip-notes or CMUX_TESTFLIGHT_SKIP_NOTES=1.
SKIP_NOTES=0
if [[ "${CMUX_TESTFLIGHT_SKIP_NOTES:-}" == "1" ]]; then
  SKIP_NOTES=1
fi
# --notes-from-range <base>: auto-generate the "What to Test" notes from the
# iOS-affecting commits in <base>..HEAD (via generate-testflight-notes.sh) instead
# of the hand-maintained ios/CHANGELOG.md top entry. Used by the every-2h beta
# lane so each build's notes reflect what actually changed since the previous
# beta for whichever audience is being shipped. When set, the changelog
# preflight + version-match guard are skipped (the notes no longer come from the
# changelog, and --auto-version stamps a version the changelog would not match).
NOTES_RANGE_BASE=""
# --auto-version: stamp the beta build's MARKETING_VERSION at archive time (no
# repo commit-back, mirroring the timestamp build number) to the next patch above
# the last iOS release, so betas show e.g. 1.0.4 while 1.0.3 is the last release.
AUTO_VERSION=0

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
    --external)
      EXTERNAL_TESTING=1
      shift
      ;;
    --export-only)
      EXPORT_ONLY=1
      shift
      ;;
    --skip-notes)
      SKIP_NOTES=1
      shift
      ;;
    --notes-from-range)
      require_option_value "$1" "${2:-}"
      NOTES_RANGE_BASE="$2"
      shift 2
      ;;
    --auto-version)
      AUTO_VERSION=1
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
    PRODUCT_BUNDLE_IDENTIFIER="${IOS_BETA_BUNDLE_ID:-dev.cmux.app.beta}"
    PROVISIONING_PROFILE_NAME="${IOS_BETA_PROVISIONING_PROFILE_NAME:-cmux Beta Distribution}"
    PRODUCT_DISPLAY_NAME="${IOS_BETA_DISPLAY_NAME:-cmux BETA}"
    CRASH_REPORTING_ENABLED="YES"
    ;;
  appstore)
    PRODUCT_BUNDLE_IDENTIFIER="${IOS_APPSTORE_BUNDLE_ID:-com.cmux.app}"
    PROVISIONING_PROFILE_NAME="${IOS_APPSTORE_PROVISIONING_PROFILE_NAME:-cmux App Store Distribution}"
    PRODUCT_DISPLAY_NAME="${IOS_APPSTORE_DISPLAY_NAME:-cmux}"
    CRASH_REPORTING_ENABLED="NO"
    ;;
  *)
    echo "error: unsupported lane '$LANE'" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "$LANE" == "appstore" && "$EXTERNAL_TESTING" -eq 1 ]]; then
  echo "error: --external is TestFlight-only and cannot be used with --lane appstore" >&2
  exit 2
fi

if [[ "$LANE" == "appstore" && "$AUTO_VERSION" -eq 1 ]]; then
  echo "error: --auto-version is beta-only. Set the configured App Store marketing version intentionally before an App Store upload." >&2
  exit 2
fi

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
SHARED_XCCONFIG="$IOS_DIR/Config/Shared.xcconfig"
CHECKED_IN_BETA_MARKETING_VERSION="$(read_xcconfig_setting CMUX_IOS_BETA_MARKETING_VERSION "$SHARED_XCCONFIG")"
CHECKED_IN_APPSTORE_MARKETING_VERSION="$(read_xcconfig_setting CMUX_IOS_APPSTORE_MARKETING_VERSION "$SHARED_XCCONFIG")"

case "$LANE" in
  beta)
    LANE_MARKETING_VERSION="${BETA_MARKETING_VERSION:-${IOS_BETA_MARKETING_VERSION:-$CHECKED_IN_BETA_MARKETING_VERSION}}"
    ;;
  appstore)
    LANE_MARKETING_VERSION="${IOS_APPSTORE_MARKETING_VERSION:-$CHECKED_IN_APPSTORE_MARKETING_VERSION}"
    ;;
esac
require_marketing_version "$LANE" "$LANE_MARKETING_VERSION"

# Notes audience is driven by the testing lane (External block for --external).
NOTES_AUDIENCE="internal"
[[ "$EXTERNAL_TESTING" == "1" ]] && NOTES_AUDIENCE="external"

# Stamp the lane's marketing version at archive time. Release.xcconfig defaults
# to the beta value for normal TestFlight builds, but the App Store lane shares
# the same Xcode configuration and must override MARKETING_VERSION explicitly so
# production can start from its own version.
MARKETING_VERSION_ARGS=( "MARKETING_VERSION=$LANE_MARKETING_VERSION" )
EXPECTED_MARKETING_VERSION="$LANE_MARKETING_VERSION"

# --auto-version: compute the beta marketing version (next patch above the last
# iOS release) and prepare it as an archive build-setting override. No repo write:
# this mirrors the timestamp BUILD_NUMBER, which is also stamped at archive time
# and never committed. Source of "last release" is the newest `ios-v<X.Y.Z>` git
# tag (the `v1.x` tags are the macOS app); fallback to the checked-in beta
# marketing version if no iOS tag exists. So while 1.0.3 is the last release,
# every beta archives as 1.0.4; a real release sets + tags the version and the
# stamp tracks it.
if [[ "$AUTO_VERSION" -eq 1 ]]; then
  # --auto-version stamps the marketing version at archive time and disables the
  # changelog version guard (RANGE_NOTES_MODE). Both only make sense when THIS
  # script archives. A reused --archive-path is already built, so there is nothing
  # to stamp and the guard would be skipped over an unknown embedded version: fail
  # closed rather than upload a prebuilt archive with a possibly-stale version.
  if [[ -n "$ARCHIVE_PATH" ]]; then
    echo "error: --auto-version cannot restamp a prebuilt --archive-path. Re-archive without --archive-path, or drop --auto-version." >&2
    exit 2
  fi
  base_version=""
  last_ios_tag="$(git -C "$IOS_DIR" tag --list 'ios-v*' --sort=-version:refname 2>/dev/null | head -1 || true)"
  if [[ "$last_ios_tag" =~ ^ios-v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    base_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  else
    base_version="$CHECKED_IN_BETA_MARKETING_VERSION"
  fi
  if version_gt "$CHECKED_IN_BETA_MARKETING_VERSION" "$base_version"; then
    base_version="$CHECKED_IN_BETA_MARKETING_VERSION"
  fi
  if [[ "$base_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    COMPUTED_BETA_MARKETING_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$(( BASH_REMATCH[3] + 1 ))"
  elif [[ "$base_version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    COMPUTED_BETA_MARKETING_VERSION="${BASH_REMATCH[1]}.$(( BASH_REMATCH[2] + 1 )).0"
  fi
  if [[ -n "${COMPUTED_BETA_MARKETING_VERSION:-}" ]]; then
    MARKETING_VERSION_ARGS=( "MARKETING_VERSION=$COMPUTED_BETA_MARKETING_VERSION" )
    EXPECTED_MARKETING_VERSION="$COMPUTED_BETA_MARKETING_VERSION"
    echo "auto-version: stamping beta MARKETING_VERSION=$COMPUTED_BETA_MARKETING_VERSION (last release base ${base_version:-unknown})" >&2
  else
    # Fail closed: --auto-version disables the changelog version guard, so if we
    # cannot compute a stamp we must not silently upload the un-bumped checked-in
    # version with the guard off.
    echo "error: --auto-version could not compute a beta version (base '${base_version:-}'); refusing to upload with the version guard disabled and no stamp. Ensure an ios-v<X.Y.Z> tag or a valid configured beta marketing version in ios/Config/Shared.xcconfig." >&2
    exit 1
  fi
elif [[ -z "$ARCHIVE_PATH" ]]; then
  echo "lane-version: stamping $LANE MARKETING_VERSION=$LANE_MARKETING_VERSION" >&2
else
  echo "lane-version: expecting $LANE MARKETING_VERSION=$LANE_MARKETING_VERSION in reused archive" >&2
fi

# Are the notes auto-generated from a commit range instead of the changelog?
# True when an explicit --notes-from-range base was given, OR when --auto-version
# is set: an auto-version build stamps the NEXT beta marketing version, which by
# design will not equal the checked-in changelog top entry, so the changelog
# preflight + version-match guard must not run for it. The range generator has its
# own empty/unreachable-base fallback, so this stays correct on the first beta or a
# missing-history lookup where NOTES_RANGE_BASE is empty (it would otherwise fall
# back to changelog validation and abort against the stale top version).
RANGE_NOTES_MODE=0
if [[ -n "$NOTES_RANGE_BASE" || "$AUTO_VERSION" -eq 1 ]]; then
  RANGE_NOTES_MODE=1
fi

# Preflight the TestFlight "What to Test" notes BEFORE the expensive archive, so a
# deterministic local error (missing ios/CHANGELOG.md, empty audience block) fails
# fast here instead of being discovered only AFTER the build is already uploaded
# (where the notes step is non-fatal). This validate-only call contacts NO network
# and needs no ASC credentials. The version-match check (changelog top == the
# build's marketing version) happens later for a reused --archive-path / post-build,
# where the actual marketing version is known. Skipped when there is no upload to
# annotate (--export-only), notes are turned off (--skip-notes), or notes come from
# a commit range (range-notes mode) rather than the changelog.
if [[ "$LANE" == "beta" && "$EXPORT_ONLY" -ne 1 && "$SKIP_NOTES" -ne 1 && "$RANGE_NOTES_MODE" -ne 1 ]]; then
  if ! "$SCRIPT_DIR/set-testflight-notes.sh" --validate-only --audience "$NOTES_AUDIENCE"; then
    echo "error: TestFlight What to Test notes preflight failed (see above). Fix ios/CHANGELOG.md before uploading, or pass --skip-notes to upload without notes." >&2
    exit 1
  fi
fi

# Resolve App Store Connect API auth (env, else local plist) BEFORE the
# monotonic guard and output-path computation below: the guard may finalize
# BUILD_NUMBER, and OUT_DIR is derived from BUILD_NUMBER.
LOCAL_ASC_CONFIG="$IOS_DIR/Config/AppStoreConnect.local.plist"
if [[ -f "$LOCAL_ASC_CONFIG" ]]; then
  ASC_API_KEY_ID="${ASC_API_KEY_ID:-$("$PLISTBUDDY" -c 'Print :ASC_API_KEY_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-$("$PLISTBUDDY" -c 'Print :ASC_API_ISSUER_ID' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
  ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$("$PLISTBUDDY" -c 'Print :ASC_API_KEY_PATH' "$LOCAL_ASC_CONFIG" 2>/dev/null || true)}"
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
  ARCHIVE_BUILD_NUMBER="$("$PLISTBUDDY" -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
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

OUT_DIR="${CMUX_IOS_UPLOAD_DIR:-/tmp/cmux-ios-$LANE-$BUILD_NUMBER}"
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
  if [[ "$SIGNING" == "automatic" ]]; then
    # Automatic signing must archive a signed app so Xcode has the requested
    # Release entitlements to preserve during App Store Connect export. The
    # iOS app target gets those entitlements from Config/Release.xcconfig; do
    # not pass CODE_SIGN_ENTITLEMENTS here because command-line build settings
    # apply to every SwiftPM target in the workspace.
    xcodebuild archive \
      -workspace "$WORKSPACE" \
      -scheme "$SCHEME" \
      -configuration Release \
      -destination "generic/platform=iOS" \
      -archivePath "$ARCHIVE_PATH" \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      "${XCODE_AUTH_ARGS[@]}" \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      PRODUCT_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER" \
      PRODUCT_DISPLAY_NAME="$PRODUCT_DISPLAY_NAME" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      CMUX_CRASH_REPORTING_ENABLED="$CRASH_REPORTING_ENABLED" \
      ${MARKETING_VERSION_ARGS[@]+"${MARKETING_VERSION_ARGS[@]}"} \
      CODE_SIGN_STYLE=Automatic \
      CODE_SIGNING_ALLOWED=YES \
      CODE_SIGNING_REQUIRED=YES \
      | tee "$OUT_DIR/archive.log"
  else
    # Manual signing archives WITHOUT signing. The export step signs with the
    # installed distribution profile, then the manual path below re-signs with
    # the full Release entitlements from the local Apple Distribution cert.
    # This keeps signing material off shared fleet builders.
    xcodebuild archive \
      -workspace "$WORKSPACE" \
      -scheme "$SCHEME" \
      -configuration Release \
      -destination "generic/platform=iOS" \
      -archivePath "$ARCHIVE_PATH" \
      -derivedDataPath "$DERIVED_DATA" \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      PRODUCT_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER" \
      PRODUCT_DISPLAY_NAME="$PRODUCT_DISPLAY_NAME" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      CMUX_CRASH_REPORTING_ENABLED="$CRASH_REPORTING_ENABLED" \
      ${MARKETING_VERSION_ARGS[@]+"${MARKETING_VERSION_ARGS[@]}"} \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      | tee "$OUT_DIR/archive.log"
  fi
else
  if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "error: archive not found: $ARCHIVE_PATH" >&2
    exit 1
  fi
fi

ARCHIVE_BUNDLE_IDENTIFIER="$("$PLISTBUDDY" -c 'Print :ApplicationProperties:CFBundleIdentifier' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
if [[ -n "$ARCHIVE_BUNDLE_IDENTIFIER" && "$ARCHIVE_BUNDLE_IDENTIFIER" != "$PRODUCT_BUNDLE_IDENTIFIER" ]]; then
  echo "error: archive bundle id is '$ARCHIVE_BUNDLE_IDENTIFIER' but lane '$LANE' requires '$PRODUCT_BUNDLE_IDENTIFIER'. Re-archive for the selected lane." >&2
  exit 1
fi
ARCHIVE_APP="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1 || true)"
if [[ -n "$ARCHIVE_APP" && -d "$ARCHIVE_APP" ]]; then
  ARCHIVE_APP_BUNDLE_IDENTIFIER="$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$ARCHIVE_APP/Info.plist" 2>/dev/null || true)"
  if [[ -n "$ARCHIVE_APP_BUNDLE_IDENTIFIER" && "$ARCHIVE_APP_BUNDLE_IDENTIFIER" != "$PRODUCT_BUNDLE_IDENTIFIER" ]]; then
    echo "error: archive app CFBundleIdentifier is '$ARCHIVE_APP_BUNDLE_IDENTIFIER' but lane '$LANE' requires '$PRODUCT_BUNDLE_IDENTIFIER'. Re-archive for the selected lane." >&2
    exit 1
  fi
  if [[ "$LANE" == "appstore" ]]; then
    ARCHIVE_CRASH_REPORTING_ENABLED="$("$PLISTBUDDY" -c 'Print :CMUXCrashReportingEnabled' "$ARCHIVE_APP/Info.plist" 2>/dev/null || true)"
    if [[ "$ARCHIVE_CRASH_REPORTING_ENABLED" != "NO" ]]; then
      echo "error: App Store archive CMUXCrashReportingEnabled is '${ARCHIVE_CRASH_REPORTING_ENABLED:-<absent>}', expected 'NO'; refusing to export" >&2
      exit 1
    fi
  fi
fi

ARCHIVE_MARKETING_VERSION="$("$PLISTBUDDY" -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
if [[ ! "$ARCHIVE_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "error: archive marketing version is unreadable or invalid ('$ARCHIVE_MARKETING_VERSION'); refusing to export an unverifiable $LANE build." >&2
  exit 1
fi
if [[ "$ARCHIVE_MARKETING_VERSION" != "$EXPECTED_MARKETING_VERSION" ]]; then
  echo "error: archive marketing version is '$ARCHIVE_MARKETING_VERSION' but lane '$LANE' requires '$EXPECTED_MARKETING_VERSION'. Re-archive for the selected lane." >&2
  exit 1
fi

# Now that the archive exists, its marketing version (CFBundleShortVersionString)
# is the version testers will see. Re-run the notes preflight WITH that version so
# a deterministic mismatch (changelog top is 1.0.3 but the archived build is 1.0.0)
# fails BEFORE the export/upload, not after (when the notes step is non-fatal and
# would just ship an opaque build). Skipped for --export-only / --skip-notes. If the
# archive's version is unreadable, the lane version guard above fails closed
# before this notes-specific check.
# Skipped in range-notes mode: the notes come from the commit range, not the
# changelog, and --auto-version intentionally stamps a version the changelog would
# not match.
if [[ "$LANE" == "beta" && "$EXPORT_ONLY" -ne 1 && "$SKIP_NOTES" -ne 1 && "$RANGE_NOTES_MODE" -ne 1 ]]; then
  if [[ "$ARCHIVE_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    if ! "$SCRIPT_DIR/set-testflight-notes.sh" --validate-only \
        --audience "$NOTES_AUDIENCE" --expect-marketing-version "$ARCHIVE_MARKETING_VERSION"; then
      echo "error: ios/CHANGELOG.md top entry does not match the archived marketing version $ARCHIVE_MARKETING_VERSION (see above); refusing to upload a build whose What to Test notes would be for the wrong version. Update ios/CHANGELOG.md, or pass --skip-notes." >&2
      exit 1
    fi
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
if [[ "$LANE" == "beta" ]]; then
  if [[ "$EXTERNAL_TESTING" == "1" ]]; then
    # External-eligible: omit/clear the internal-only restriction so the build can
    # be added to an external group (after Apple Beta App Review).
    plutil -insert testFlightInternalTestingOnly -bool NO "$EXPORT_OPTIONS"
    echo "note: --external set; build will be eligible for external TestFlight testers (requires Apple Beta App Review per version)." >&2
  else
    plutil -insert testFlightInternalTestingOnly -bool YES "$EXPORT_OPTIONS"
  fi
fi
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
  "$PLISTBUDDY" -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS"
  "$PLISTBUDDY" -c "Add :provisioningProfiles:$PRODUCT_BUNDLE_IDENTIFIER string $PROVISIONING_PROFILE_NAME" "$EXPORT_OPTIONS"
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

# Re-sign the exported app with the FULL entitlements (production aps-environment
# et al.), then point $IPA_PATH at the re-signed IPA so the upload below ships it.
#
# Why this is necessary for the manual path: the archive is built UNSIGNED
# (CODE_SIGNING_ALLOWED=NO, see above) to keep distribution material off shared
# fleet builders. An unsigned archive carries NO entitlements, so
# `-exportArchive` re-adds only the profile baseline (application-identifier,
# com.apple.developer.team-identifier, get-task-allow, beta-reports-active) and
# SILENTLY DROPS app-capability entitlements such as aps-environment. This
# regressed in
# https://github.com/manaflow-ai/cmux/pull/5496 (June 2026): the signed beta IPA
# had aps-environment absent entirely, so the device registered no push token and
# beta/prod push was dead. The per-config entitlements file fix
# (Config/cmux-release.entitlements) is necessary but NOT sufficient on its own:
# a config-level entitlement only ships if it survives into the signed binary,
# and only `codesign -d --entitlements` on the EXPORTED app proves that. So we
# re-sign here with the export baseline MERGED with the Release entitlements file.
#
# The merged set MUST then be reconciled against the provisioning profile, in
# both directions (hit 2026-06-11, ASC error 90163): App Store Connect rejects
# any signed entitlement key the profile does not authorize. The Release file
# carries com.apple.developer.usernotifications.time-sensitive, the App ID has
# the capability enabled, but the installed "cmux Beta Distribution" profile
# predates it and does not list the key, so a naive baseline+Release merge is
# rejected at upload ("bundle contains a key not in the provisioning profile").
# The same naive merge also SHIPS WITHOUT keychain-access-groups (authorized by
# the profile but absent from both the export baseline and the Release file).
# So below we (1) seed from the profile's own Entitlements dict, the exact set
# ASC validates against, and (2) drop any merged key the profile does not
# authorize, warning per key. Restoring a dropped capability (e.g.
# time-sensitive) requires REGENERATING the profile so it snapshots the App
# ID's current capabilities, not editing this script or the Release file.
#
# This runs on the MANUAL signing path only: it re-signs with the named
# distribution cert from the local keychain ("Apple Distribution: Manaflow,
# Inc."), which is present for local/fleet-archive beta cuts. The cmux iOS app is
# a single self-contained bundle (no Frameworks/, no PlugIns/, GhosttyKit is
# static), so only the top-level .app is signed; there is no nested code to
# re-sign. Two alternatives were ruled out: an ad-hoc archive (CODE_SIGN_IDENTITY
# "-") is rejected by the iOS SDK for an entitled app, and signing on the shared
# fleet would put distribution material on shared Macs.
if [[ "$SIGNING" == "manual" ]]; then
  # Resolve the Release entitlements file. Release.xcconfig statically sets
  # CODE_SIGN_ENTITLEMENTS = Config/cmux-release.entitlements, so default to that
  # path rather than parsing xcodebuild -showBuildSettings (slower, more brittle).
  RELEASE_ENTITLEMENTS="${IOS_RELEASE_ENTITLEMENTS:-$IOS_DIR/Config/cmux-release.entitlements}"
  RESIGN_IDENTITY="${IOS_DISTRIBUTION_IDENTITY:-Apple Distribution: Manaflow, Inc. (7WLXT3NR37)}"

  if [[ ! -f "$RELEASE_ENTITLEMENTS" ]]; then
    echo "error: re-sign needs the Release entitlements file but it is missing: $RELEASE_ENTITLEMENTS (set IOS_RELEASE_ENTITLEMENTS to override)" >&2
    exit 1
  fi
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$RESIGN_IDENTITY"; then
    echo "error: re-sign needs the distribution identity '$RESIGN_IDENTITY' in the keychain, but it was not found (security find-identity -v -p codesigning). Set IOS_DISTRIBUTION_IDENTITY, or run on a Mac with the Apple Distribution cert." >&2
    exit 1
  fi

  RESIGN_DIR="$OUT_DIR/resign"
  rm -rf "$RESIGN_DIR"
  mkdir -p "$RESIGN_DIR"
  ( cd "$RESIGN_DIR" && unzip -q "$IPA_PATH" )
  RESIGN_APP="$(find "$RESIGN_DIR/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
  if [[ -z "$RESIGN_APP" || ! -d "$RESIGN_APP" ]]; then
    echo "error: could not find Payload/*.app inside the exported IPA to re-sign" >&2
    exit 1
  fi

  # Xcode embeds SPM binaryTarget frameworks into Frameworks/ even when the
  # framework's binary is a STATIC archive (ar), e.g. iroh-ffi's Iroh.framework.
  # The linker already folded that code into the app executable, so the embedded
  # copy is inert — and App Store Connect rejects it in processing with
  # ITMS-90208 regardless of the app's deployment target or the framework's
  # Info.plist. Depending on the Xcode version, export-time distribution
  # processing may also strip the static executable and leave an INVALID SHELL
  # (Info.plist with no binary), which ASC rejects the same way; build
  # 20260716043221 shipped exactly that past an ar-archive-only check here.
  # So the keep policy is a whitelist, not a blacklist: an embedded framework
  # stays ONLY if its executable exists and is a dynamically linked Mach-O.
  # Everything else is stripped, gated on the app executable not referencing
  # the framework in its dynamic load commands. Every framework's state is
  # logged first so a future ASC rejection comes with ground truth.
  RESIGN_APP_EXECUTABLE="$RESIGN_APP/$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$RESIGN_APP/Info.plist")"
  if [[ -d "$RESIGN_APP/Frameworks" ]]; then
    echo "embedded Frameworks/ contents before static-framework strip:"
    find "$RESIGN_APP/Frameworks" -maxdepth 2 -print | sed "s|$RESIGN_APP/||"
  fi
  while IFS= read -r -d '' embedded_fw; do
    embedded_fw_name="$(basename "$embedded_fw" .framework)"
    embedded_fw_exec_name="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$embedded_fw/Info.plist" 2>/dev/null || echo "$embedded_fw_name")"
    embedded_fw_bin="$embedded_fw/$embedded_fw_exec_name"
    if [[ -f "$embedded_fw_bin" ]]; then
      embedded_fw_kind="$(file -b "$embedded_fw_bin")"
    else
      embedded_fw_kind="<executable missing>"
    fi
    echo "embedded framework ${embedded_fw_name}.framework binary: $embedded_fw_kind"
    if [[ "$embedded_fw_kind" == *"dynamically linked shared library"* ]]; then
      # ROOT CAUSE of the ITMS-90208 rejections (proven by build
      # 20260716050845's diagnostics): Xcode synthesizes the embedded dylib
      # for a static SPM binaryTarget at build time and stamps it with the
      # APP's deployment target (minos 18.4), but copies the xcframework's
      # Info.plist unchanged (MinimumOSVersion 17.5). ASC rejects the
      # internally inconsistent bundle: its binary cannot run on the minimum
      # OS its own Info.plist declares. Reconcile the plist to the binary's
      # actual minos, then re-sign the framework (its seal covers Info.plist);
      # the app itself is force-re-signed right after this block.
      embedded_fw_minos="$(xcrun vtool -show-build "$embedded_fw_bin" 2>/dev/null | awk '/^ *minos /{print $2; exit}')"
      embedded_fw_plist_min="$("$PLISTBUDDY" -c 'Print :MinimumOSVersion' "$embedded_fw/Info.plist" 2>/dev/null || true)"
      echo "embedded framework ${embedded_fw_name}.framework: binary minos=${embedded_fw_minos:-<none>} Info.plist MinimumOSVersion=${embedded_fw_plist_min:-<absent>}"
      if [[ -n "$embedded_fw_minos" ]]; then
        embedded_fw_lowest="$(printf '%s\n%s\n' "${embedded_fw_plist_min:-0}" "$embedded_fw_minos" | sort -V | head -n 1)"
        if [[ -z "$embedded_fw_plist_min" || ( "$embedded_fw_plist_min" != "$embedded_fw_minos" && "$embedded_fw_lowest" == "$embedded_fw_plist_min" ) ]]; then
          echo "reconciling ${embedded_fw_name}.framework Info.plist MinimumOSVersion ${embedded_fw_plist_min:-<absent>} -> $embedded_fw_minos (must match the binary or ASC rejects with ITMS-90208)"
          if [[ -z "$embedded_fw_plist_min" ]]; then
            "$PLISTBUDDY" -c "Add :MinimumOSVersion string $embedded_fw_minos" "$embedded_fw/Info.plist"
          else
            "$PLISTBUDDY" -c "Set :MinimumOSVersion $embedded_fw_minos" "$embedded_fw/Info.plist"
          fi
          codesign --force --sign "$RESIGN_IDENTITY" --timestamp "$embedded_fw"
        fi
      fi
      continue
    fi
    if otool -L "$RESIGN_APP_EXECUTABLE" | grep -qF "/${embedded_fw_name}.framework/"; then
      echo "error: app executable dynamically links ${embedded_fw_name}.framework but the embedded copy is not a valid dynamic library ($embedded_fw_kind); refusing to strip or upload" >&2
      exit 1
    fi
    echo "stripping embedded framework without a valid dynamic-library executable ($embedded_fw_kind); its code is statically linked into the app executable and ASC rejects the leftover bundle (ITMS-90208): Frameworks/${embedded_fw_name}.framework"
    rm -rf "$embedded_fw"
  done < <(find "$RESIGN_APP/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0 2>/dev/null)
  # An empty Frameworks/ dir after stripping is pointless; remove it so the
  # bundle matches the historical no-Frameworks layout.
  rmdir "$RESIGN_APP/Frameworks" 2>/dev/null || true

  # Start from the exported app's current (profile-baseline) entitlements, then
  # MERGE the profile's authorized Entitlements dict, then every key from the
  # Release entitlements file. The merge is GENERIC: PlistBuddy Merge copies all
  # keys from the source and skips any that already exist, so future entitlements
  # survive automatically and existing baseline values (e.g. get-task-allow=false)
  # are preserved. Seeding from the profile is what carries profile-authorized
  # keys that appear in NEITHER the baseline NOR the Release file (concretely:
  # keychain-access-groups, which the 2026-06-10 accepted upload shipped and a
  # baseline+Release-only merge silently lost).
  MERGED_ENTITLEMENTS="$RESIGN_DIR/entitlements.plist"
  codesign -d --entitlements :- --xml "$RESIGN_APP" > "$MERGED_ENTITLEMENTS" 2>/dev/null || {
    echo "error: could not read current entitlements from the exported app: $RESIGN_APP" >&2
    exit 1
  }
  PROFILE_ENTITLEMENTS="$RESIGN_DIR/profile-entitlements.plist"
  security cms -D -i "$RESIGN_APP/embedded.mobileprovision" > "$RESIGN_DIR/profile.plist" || {
    echo "error: could not decode embedded.mobileprovision from the exported app: $RESIGN_APP" >&2
    exit 1
  }
  plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS" "$RESIGN_DIR/profile.plist"
  # `|| true`: PlistBuddy Merge prints "Duplicate Entry Was Skipped" if a
  # source key overlaps an existing key. That is the intended behavior
  # (existing wins), but its exit code on that path is not contractually 0 across
  # OS versions, and a stray non-zero would kill the script under `set -e`. The
  # exit code is non-load-bearing anyway: a genuinely failed merge produces no
  # aps-environment and is caught by the hard gate below with a clear error.
  "$PLISTBUDDY" -c "Merge $PROFILE_ENTITLEMENTS" "$MERGED_ENTITLEMENTS" >/dev/null || true
  "$PLISTBUDDY" -c "Merge $RELEASE_ENTITLEMENTS" "$MERGED_ENTITLEMENTS" >/dev/null || true
  # Intersect against the profile: ASC rejects the upload (error 90163, "bundle
  # contains a key not in the provisioning profile") for ANY signed key the
  # profile does not authorize. Baseline keys are authorized by construction
  # (the export minted them FROM this profile), so a strict top-level-key
  # intersection is safe. Each dropped key is warned so the loss is visible in
  # the cut log (e.g. time-sensitive until the profile is regenerated).
  python3 - "$MERGED_ENTITLEMENTS" "$PROFILE_ENTITLEMENTS" <<'PY'
import plistlib, sys
merged_path, profile_path = sys.argv[1], sys.argv[2]
with open(merged_path, "rb") as f:
    merged = plistlib.load(f)
with open(profile_path, "rb") as f:
    profile = plistlib.load(f)
for key in [k for k in merged if k not in profile]:
    del merged[key]
    print(
        f"warning: dropping entitlement the provisioning profile does not "
        f"authorize (ASC error 90163 otherwise): {key}",
        file=sys.stderr,
    )
with open(merged_path, "wb") as f:
    plistlib.dump(merged, f)
PY
  plutil -lint "$MERGED_ENTITLEMENTS" >/dev/null

  codesign --force --sign "$RESIGN_IDENTITY" --entitlements "$MERGED_ENTITLEMENTS" --timestamp "$RESIGN_APP"

  # HARD GATES on the signed .app: the entitlement we are fixing must be present,
  # and the signature must be strictly valid. A config-level check cannot prove
  # either; only codesign on the actual binary does.
  if ! codesign -d --entitlements :- --xml "$RESIGN_APP" 2>/dev/null | plutil -p - | grep -q '"aps-environment"'; then
    echo "error: re-signed app is still missing aps-environment; refusing to upload a push-broken build" >&2
    codesign -d --entitlements :- --xml "$RESIGN_APP" 2>/dev/null | plutil -p - >&2 || true
    exit 1
  fi
  codesign --verify --strict --verbose=2 "$RESIGN_APP"

  # Re-zip with the exact IPA layout (Payload/ at archive root) and repoint
  # $IPA_PATH so the existing upload step ships the re-signed IPA.
  RESIGNED_IPA="$EXPORT_PATH/cmux-resigned.ipa"
  rm -f "$RESIGNED_IPA"
  ( cd "$RESIGN_DIR" && zip -qrX "$RESIGNED_IPA" Payload )

  # Post-zip gate: a wrong Payload root or stripped attributes corrupts the bundle
  # silently, and the whole point is that aps-environment survives. Re-verify the
  # produced IPA (strict signature + aps-environment) so altool is not the first
  # thing to notice. Same shared check the automatic path uses.
  if ! verify_ipa_aps_environment_production "$RESIGNED_IPA"; then
    echo "error: re-signed IPA failed verification (corrupt bundle, or aps-environment not production); refusing to upload" >&2
    exit 1
  fi

  IPA_PATH="$RESIGNED_IPA"
  echo "re-signed IPA with full entitlements (aps-environment=production): $IPA_PATH"
else
  # Automatic (cloud-managed) signing: there is no named distribution cert in the
  # keychain to re-sign with, so we cannot re-add a dropped entitlement here. The
  # archive is unsigned and -exportArchive does NOT mine the profile's
  # app-capability entitlements (verified: even a manual export with the
  # push-capable "cmux Beta Distribution" profile produced only the 4-key baseline
  # with no aps-environment), so an automatic export almost certainly drops it too.
  #
  # Rather than upload a known-push-broken build with only a warning (CI warnings
  # are effectively silent, and ios-testflight.yml drives the PRIMARY beta cut with
  # --signing automatic), FAIL CLOSED: verify the exported IPA actually carries
  # aps-environment, and refuse the upload if it does not. If automatic ever does
  # preserve it, the gate passes and upload proceeds.
  #
  # To make CI cut a push-WORKING beta, ios-testflight.yml must import the iOS
  # distribution cert and call this script with --signing manual (nightly.yml /
  # release.yml already import a signing cert on ephemeral runners, so the pattern
  # exists). That is a security-relevant workflow + secrets decision, deliberately
  # out of scope here; this gate just stops shipping a broken artifact until then.
  if ! verify_ipa_aps_environment_production "$IPA_PATH"; then
    echo "error: --signing automatic produced an IPA without aps-environment=production; refusing to upload a push-broken beta. Cut the beta via --signing manual (import the iOS distribution cert in CI), or re-sign with the distribution cert." >&2
    exit 1
  fi
  echo "automatic-signed IPA verified to carry aps-environment=production: $IPA_PATH"
fi

if ! verify_ipa_framework_minimum_os_versions "$IPA_PATH"; then
  echo "error: signed IPA contains invalid framework deployment metadata; refusing to upload" >&2
  exit 1
fi
echo "signed IPA framework deployment metadata verified"

echo "IPA_PATH=$IPA_PATH"

EXPECTED_IPA_CRASH_REPORTING=""
[[ "$LANE" == "appstore" ]] && EXPECTED_IPA_CRASH_REPORTING="NO"
if ! verify_ipa_bundle_identity "$IPA_PATH" "$PRODUCT_BUNDLE_IDENTIFIER" "$DEVELOPMENT_TEAM" "$EXPECTED_IPA_CRASH_REPORTING"; then
  echo "error: signed IPA bundle identity does not match lane '$LANE'; refusing to upload" >&2
  exit 1
fi
echo "signed IPA bundle identity verified: $PRODUCT_BUNDLE_IDENTIFIER"

if [[ "$LANE" == "appstore" ]]; then
  if ! verify_app_store_ipa_has_no_external_purchase_links "$IPA_PATH"; then
    exit 1
  fi
  echo "App Store IPA verified to omit external purchase/enrollment links: $IPA_PATH"
fi

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  exit 0
fi

upload_app_store_with_asc() {
  if [[ -z "${ASC_APP_ID:-}" ]]; then
    echo "error: --lane appstore requires a configured numeric app id so the upload targets the expected app record" >&2
    exit 2
  fi
  if [[ ! "$ASC_APP_ID" =~ ^[0-9]+$ ]]; then
    echo "error: --lane appstore requires the configured app id to be numeric; do not pass a bundle id" >&2
    exit 2
  fi
  if ! command -v asc >/dev/null 2>&1; then
    echo "error: --lane appstore requires the release upload CLI for app-id based upload" >&2
    exit 2
  fi

  local asc_private_key_path="${ASC_API_KEY_PATH:-}"
  local asc_private_key_b64="${ASC_API_KEY_P8_BASE64:-}"
  if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" || ( -z "$asc_private_key_path" && -z "$asc_private_key_b64" ) ]]; then
    echo "error: --lane appstore upload requires complete upload credentials" >&2
    exit 2
  fi
  if [[ -n "$asc_private_key_path" && ! -f "$asc_private_key_path" ]]; then
    echo "error: configured private key path does not exist: $asc_private_key_path" >&2
    exit 2
  fi

  local asc_home="$OUT_DIR/asc-home"
  local asc_xdg_config="$OUT_DIR/asc-xdg-config"
  local asc_xdg_cache="$OUT_DIR/asc-xdg-cache"
  mkdir -p "$asc_home" "$asc_xdg_config" "$asc_xdg_cache"

  local asc_env=(
    "HOME=$asc_home"
    "XDG_CONFIG_HOME=$asc_xdg_config"
    "XDG_CACHE_HOME=$asc_xdg_cache"
    "ASC_BYPASS_KEYCHAIN=1"
    "ASC_STRICT_AUTH=true"
    "ASC_NO_UPDATE=1"
    "ASC_KEY_ID=$ASC_API_KEY_ID"
    "ASC_ISSUER_ID=$ASC_API_ISSUER_ID"
  )
  if [[ -n "$asc_private_key_path" ]]; then
    asc_env+=( "ASC_PRIVATE_KEY_PATH=$asc_private_key_path" )
  fi
  if [[ -n "$asc_private_key_b64" ]]; then
    asc_env+=( "ASC_PRIVATE_KEY_B64=$asc_private_key_b64" )
  fi

  local asc_app_json="$OUT_DIR/asc-app.json"
  (
    export "${asc_env[@]}"
    asc apps view --id "$ASC_APP_ID" --output json > "$asc_app_json"
  )

  local asc_bundle_id
  asc_bundle_id="$(
    python3 - "$asc_app_json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    body = json.load(handle)

def bundle_id(value):
    if isinstance(value, dict):
        for key in ("bundleId", "bundle_id", "bundleIdentifier", "bundle_identifier"):
            found = value.get(key)
            if isinstance(found, str) and found:
                return found
        for key in ("attributes", "data", "app", "result"):
            found = bundle_id(value.get(key))
            if found:
                return found
    elif isinstance(value, list):
        for item in value:
            found = bundle_id(item)
            if found:
                return found
    return ""

found = bundle_id(body)
if not found:
    raise SystemExit(1)
print(found)
PY
  )" || {
    echo "error: could not read bundle id from configured app record" >&2
    exit 2
  }
  if [[ "$asc_bundle_id" != "$PRODUCT_BUNDLE_IDENTIFIER" ]]; then
    echo "error: configured app record has bundle id '$asc_bundle_id', but lane '$LANE' is exporting '$PRODUCT_BUNDLE_IDENTIFIER'; refusing to upload" >&2
    exit 1
  fi
  echo "configured app record verified: $ASC_APP_ID bundle id $asc_bundle_id"

  (
    export "${asc_env[@]}"
    asc builds upload \
      --app "$ASC_APP_ID" \
      --ipa "$IPA_PATH" \
      --output json
  ) | tee "$OUT_DIR/upload.log"
}

HAS_COMPLETE_ASC_UPLOAD_ENV=0
if [[ -n "${ASC_APP_ID:-}" && -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" && ( -n "${ASC_API_KEY_PATH:-}" || -n "${ASC_API_KEY_P8_BASE64:-}" ) ]]; then
  HAS_COMPLETE_ASC_UPLOAD_ENV=1
fi

HAS_ANY_ASC_UPLOAD_ENV=0
if [[ -n "${ASC_APP_ID:-}" || -n "${ASC_API_KEY_ID:-}" || -n "${ASC_API_ISSUER_ID:-}" || -n "${ASC_API_KEY_PATH:-}" || -n "${ASC_API_KEY_P8_BASE64:-}" ]]; then
  HAS_ANY_ASC_UPLOAD_ENV=1
fi

HAS_APPLE_ID_UPLOAD_ENV=0
if [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -n "${APPLE_PROVIDER_PUBLIC_ID:-}" ]]; then
  HAS_APPLE_ID_UPLOAD_ENV=1
fi

if [[ "$LANE" == "appstore" && "$HAS_COMPLETE_ASC_UPLOAD_ENV" -eq 1 ]]; then
  upload_app_store_with_asc
elif [[ "$LANE" == "appstore" && "$HAS_ANY_ASC_UPLOAD_ENV" -eq 1 && "$HAS_APPLE_ID_UPLOAD_ENV" -ne 1 ]]; then
  upload_app_store_with_asc
elif [[ "$LANE" != "appstore" && ( -n "${ASC_API_KEY_ID:-}" || -n "${ASC_API_ISSUER_ID:-}" || -n "${ASC_API_KEY_PATH:-}" ) ]]; then
  if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" || -z "${ASC_API_KEY_PATH:-}" ]]; then
    echo "error: upload credentials must be set together" >&2
    exit 2
  fi
  if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
    echo "error: configured private key path does not exist: $ASC_API_KEY_PATH" >&2
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
elif [[ "$HAS_APPLE_ID_UPLOAD_ENV" -eq 1 ]]; then
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
error: missing App Store Connect upload credentials.

Set ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH, or set
APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_PROVIDER_PUBLIC_ID. You can
also create ios/Config/AppStoreConnect.local.plist with the ASC_* keys.
EOF
  exit 2
fi

# Set the TestFlight "What to Test" notes from the top ios/CHANGELOG.md entry so
# the build is not an opaque MARKETING_VERSION (timestamp) on install/update.
#
# Non-fatal by design: the binary is already on TestFlight at this point. A failure
# to set notes (build still processing past the timeout, transient API error) must
# NOT fail the upload, so a `set -e` script must not let a non-zero exit propagate.
# The notes can always be re-applied later with set-testflight-notes.sh. The notes
# API needs the ASC API key (JWT); the Apple ID upload path has no key, so notes are
# only attempted when the ASC API creds are present.
#
# Audience: --external uses the External audience; the default internal cut uses
# the terse Internal block. SHIPPED_BUILD_NUMBER is the CFBundleVersion that
# actually shipped (post-guard, or the reused archive's embedded version).
if [[ "$LANE" != "beta" ]]; then
  echo "note: lane '$LANE' is not a TestFlight lane; skipping TestFlight What to Test notes" >&2
elif [[ "$SKIP_NOTES" -eq 1 ]]; then
  echo "note: --skip-notes set; not setting TestFlight What to Test notes" >&2
elif [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" || ( -z "${ASC_API_KEY_PATH:-}" && -z "${ASC_API_KEY_P8_BASE64:-}" ) ]]; then
  echo "note: no ASC API key (JWT) available; skipping TestFlight What to Test notes (set ASC_API_KEY_ID/ASC_API_ISSUER_ID/ASC_API_KEY_PATH, or run ios/scripts/set-testflight-notes.sh later)" >&2
else
  # The local preconditions (changelog present, audience block non-empty, top
  # version == the archived marketing version) were already enforced FATALLY before
  # the upload. This post-upload step is the ONLY non-fatal part: it just performs
  # the App Store Connect mutation, which can legitimately fail transiently (build
  # still processing past the timeout, network/API hiccup) without that meaning the
  # release is broken. The binary is already on TestFlight; the notes can be
  # re-applied later. NOTES_AUDIENCE was set early. Re-read the archived marketing
  # version so the mutation still carries the version-match guard.
  NOTES_MARKETING_VERSION="$("$PLISTBUDDY" -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
  # In range-notes mode the notes come from the commit range (not the changelog),
  # so pass them via --notes and skip the changelog version-match
  # (--expect-marketing-version validates the changelog top, which we are not
  # using). The generator self-falls-back when the base is empty/unreachable, so an
  # auto-version build with no previous-beta SHA still gets a valid fallback line
  # here instead of dropping back to changelog validation. Otherwise keep the
  # changelog-driven behavior + version-match guard.
  NOTES_SOURCE_ARGS=()
  NOTES_SOURCE_DESC="ios/CHANGELOG.md"
  if [[ "$RANGE_NOTES_MODE" -eq 1 ]]; then
    # Keep generator stderr on the CI transcript (its fallback/unreachable-base
    # diagnostics are useful); only swallow a non-zero EXIT so a generator hiccup
    # cannot fail the already-uploaded build. Guard against an empty result: an
    # empty --notes would be treated downstream as "no override" and silently fall
    # back to changelog mode (the wrong notes for an auto-version build), or push
    # blank What to Test. Substitute the generator's own fallback line instead.
    GENERATED_NOTES="$("$SCRIPT_DIR/generate-testflight-notes.sh" "$NOTES_RANGE_BASE" --audience "$NOTES_AUDIENCE" || true)"
    if [[ -z "$GENERATED_NOTES" ]]; then
      GENERATED_NOTES="- Latest main; no notable iOS changes detected since the previous build."
      echo "warning: notes generator produced no output; using the fallback What to Test line" >&2
    fi
    NOTES_SOURCE_ARGS=( --notes "$GENERATED_NOTES" )
    if [[ -n "$NOTES_RANGE_BASE" ]]; then
      NOTES_SOURCE_DESC="commits since the previous beta (${NOTES_RANGE_BASE})"
    else
      NOTES_SOURCE_DESC="auto-generated notes (no previous beta; fallback)"
    fi
  elif [[ "$NOTES_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    NOTES_SOURCE_ARGS=( --expect-marketing-version "$NOTES_MARKETING_VERSION" )
  fi
  echo "setting TestFlight '$NOTES_AUDIENCE' What to Test notes for build $SHIPPED_BUILD_NUMBER (${NOTES_MARKETING_VERSION:-unknown version}) from ${NOTES_SOURCE_DESC}" >&2
  if ASC_API_KEY_ID="$ASC_API_KEY_ID" ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
     ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}" ASC_API_KEY_P8_BASE64="${ASC_API_KEY_P8_BASE64:-}" \
     "$SCRIPT_DIR/set-testflight-notes.sh" \
       --build-number "$SHIPPED_BUILD_NUMBER" \
       --audience "$NOTES_AUDIENCE" \
       --bundle-id "$PRODUCT_BUNDLE_IDENTIFIER" \
       "${NOTES_SOURCE_ARGS[@]}"; then
    echo "TestFlight What to Test notes set for build $SHIPPED_BUILD_NUMBER" >&2
  else
    echo "warning: could not set TestFlight What to Test notes for build $SHIPPED_BUILD_NUMBER (the upload succeeded; re-run ios/scripts/set-testflight-notes.sh --build-number $SHIPPED_BUILD_NUMBER --audience $NOTES_AUDIENCE once the build finishes processing)" >&2
  fi
fi

# --external means "ship to founders", not merely "make this build externally
# eligible in principle". After upload, assign the processed build to the app's
# external beta group so external testers actually receive it, and create the
# Beta App Review submission when Apple requires one for a new
# beta marketing version. This is fatal: a red CI/upload is preferable to
# claiming the external lane tracked main when the build never reached the
# founders lane.
if [[ "$LANE" == "beta" && "$EXPORT_ONLY" -ne 1 && "$EXTERNAL_TESTING" -eq 1 && "$ASSIGN_EXTERNAL_GROUP" -eq 1 ]]; then
  if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" || ( -z "${ASC_API_KEY_PATH:-}" && -z "${ASC_API_KEY_P8_BASE64:-}" ) ]]; then
    echo "warning: no ASC API key (JWT) available; uploaded the external-eligible build but skipped automatic external-group assignment and Beta App Review submission. Supply ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH (or ASC_API_KEY_P8_BASE64) to distribute the build automatically." >&2
    exit 0
  fi
  echo "assigning external TestFlight build $SHIPPED_BUILD_NUMBER to the founders beta group" >&2
  ASC_API_KEY_ID="$ASC_API_KEY_ID" ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
    ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}" ASC_API_KEY_P8_BASE64="${ASC_API_KEY_P8_BASE64:-}" \
    CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID="${CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID:-}" \
    CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME="${CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME:-}" \
    python3 "$SCRIPT_DIR/asc_assign_external_testflight_group.py" \
      --bundle-id "$PRODUCT_BUNDLE_IDENTIFIER" \
      --build-number "$SHIPPED_BUILD_NUMBER"
fi
