#!/usr/bin/env bash
set -euo pipefail

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
  aps="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$ent" 2>/dev/null || true)"
  if [[ "$aps" != "production" ]]; then
    echo "error: signed app aps-environment is '${aps:-<absent>}', expected 'production' (push would silently fail): $app" >&2
    plutil -p "$ent" >&2 || true
    rm -rf "$workdir"
    return 1
  fi
  apple_sign_in="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin:0' "$ent" 2>/dev/null || true)"
  if [[ "$apple_sign_in" != "Default" ]]; then
    echo "error: signed app com.apple.developer.applesignin is '${apple_sign_in:-<absent>}', expected 'Default' (Sign in with Apple would fail): $app" >&2
    plutil -p "$ent" >&2 || true
    rm -rf "$workdir"
    return 1
  fi
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

  beta     bundle id: dev.cmux.app.beta   profile: cmux Beta Distribution  name: "cmux BETA"
  appstore bundle id: com.cmux.app        profile: cmux Distribution       name: "cmux"

The appstore lane uploads to the public iOS app record's TestFlight; attach the
processed build to the App Store version in App Store Connect (it does not
auto-submit). Override profile names with IOS_BETA_PROVISIONING_PROFILE_NAME /
IOS_PROD_PROVISIONING_PROFILE_NAME.

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

Options:
  --lane <beta|appstore>    Distribution lane. beta is the existing TestFlight
                            path. appstore/prod uploads the com.cmux.app
                            production App Store build and skips TestFlight
                            notes/group assignment.
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
  --auto-version            Stamp the build's MARKETING_VERSION at archive time
                            (no repo commit) to the next patch above the last
                            iOS release (newest ios-v<X.Y.Z> tag, else the
                            checked-in MARKETING_VERSION), so betas show e.g.
                            1.0.4 while 1.0.3 is the last release. Implies
                            range-notes mode (skips the changelog preflight and
                            version-match guard, since the stamped version
                            deliberately will not match the changelog top); when
                            no --notes-from-range base is given the generator
                            emits its fallback line.
  --marketing-version <v>   Stamp an explicit MARKETING_VERSION (X.Y or X.Y.Z) at
                            archive time. Use for the appstore lane so the build
                            lands in the exact version train the ASC store version
                            uses (e.g. 1.0) and can be attached. Mutually
                            exclusive with --auto-version.
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
# Whether the exported build is eligible for external TestFlight testers.
# Default 0 keeps the historical internal-only behavior (fast dogfood, no Apple
# review). Set to 1 by --external or CMUX_TESTFLIGHT_EXTERNAL=1 to drop the
# testFlightInternalTestingOnly flag so the build can be added to an external
# group; such builds then require a one-time Apple Beta App Review per
# MARKETING_VERSION.
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
# --auto-version: stamp the build's MARKETING_VERSION at archive time (no repo
# commit-back, mirroring the timestamp build number) to the next patch above the
# last iOS release, so betas show e.g. 1.0.4 while 1.0.3 is the last release.
AUTO_VERSION=0
# --marketing-version <X.Y[.Z]>: stamp an EXPLICIT MARKETING_VERSION at archive
# time. For the App Store lane a build must land in the exact version train the
# ASC store version uses (e.g. "1.0") to be attachable; the beta --auto-version
# bump (1.0.3 -> 1.0.4) would produce a mismatched train. Mutually exclusive with
# --auto-version.
EXPLICIT_MARKETING_VERSION=""

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
    --marketing-version)
      require_option_value "$1" "${2:-}"
      EXPLICIT_MARKETING_VERSION="$2"
      shift 2
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

if [[ "$LANE" == "prod" ]]; then
  LANE="appstore"
fi

# Per-lane on-device display name. Empty keeps the xcconfig default
# (Release.xcconfig = "cmux BETA"); the appstore lane overrides it to "cmux" so
# the public build ships with the clean brand name while beta stays "cmux BETA".
case "$LANE" in
  beta)
    PRODUCT_BUNDLE_IDENTIFIER="dev.cmux.app.beta"
    PROVISIONING_PROFILE_NAME="${IOS_BETA_PROVISIONING_PROFILE_NAME:-cmux Beta Distribution}"
    PRODUCT_DISPLAY_NAME="${IOS_BETA_DISPLAY_NAME:-cmux BETA}"
    ;;
  appstore)
    # Public App Store build. Distinct bundle id (clean reverse-DNS of cmux.com)
    # and a dedicated App Store distribution profile, so it ships side-by-side
    # with the beta channel. Keep com.cmux.app in lockstep with the APNs route
    # policy (web/services/apns/routePolicy.ts) and MobileBuildType.
    PRODUCT_BUNDLE_IDENTIFIER="${IOS_APPSTORE_BUNDLE_ID:-${IOS_PROD_BUNDLE_ID:-com.cmux.app}}"
    PROVISIONING_PROFILE_NAME="${IOS_APPSTORE_PROVISIONING_PROFILE_NAME:-${IOS_PROD_PROVISIONING_PROFILE_NAME:-cmux Distribution}}"
    PRODUCT_DISPLAY_NAME="${IOS_APPSTORE_DISPLAY_NAME:-${IOS_PROD_DISPLAY_NAME:-cmux}}"
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
  echo "error: --auto-version is beta-only. Set ios/Config/Shared.xcconfig MARKETING_VERSION intentionally before an App Store upload." >&2
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

# Notes audience is driven by the testing lane (External block for --external).
NOTES_AUDIENCE="internal"
[[ "$EXTERNAL_TESTING" == "1" ]] && NOTES_AUDIENCE="external"

# --auto-version: compute the beta marketing version (next patch above the last
# iOS release) and prepare it as an archive build-setting override. No repo write:
# this mirrors the timestamp BUILD_NUMBER, which is also stamped at archive time
# and never committed. Source of "last release" is the newest `ios-v<X.Y.Z>` git
# tag (the `v1.x` tags are the macOS app); fallback to the checked-in
# MARKETING_VERSION if no iOS tag exists. So while 1.0.3 is the last release, every
# beta archives as 1.0.4; a real release sets + tags the version and the stamp
# tracks it.
MARKETING_VERSION_ARGS=()
BETA_MARKETING_VERSION=""
if [[ -n "$EXPLICIT_MARKETING_VERSION" ]]; then
  if [[ "$AUTO_VERSION" -eq 1 ]]; then
    echo "error: --marketing-version and --auto-version are mutually exclusive." >&2
    exit 2
  fi
  if [[ -n "$ARCHIVE_PATH" ]]; then
    echo "error: --marketing-version cannot restamp a prebuilt --archive-path. Re-archive without --archive-path." >&2
    exit 2
  fi
  if [[ ! "$EXPLICIT_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: --marketing-version '$EXPLICIT_MARKETING_VERSION' must be X.Y or X.Y.Z" >&2
    exit 2
  fi
  MARKETING_VERSION_ARGS=( "MARKETING_VERSION=$EXPLICIT_MARKETING_VERSION" )
  echo "marketing-version: stamping MARKETING_VERSION=$EXPLICIT_MARKETING_VERSION" >&2
fi
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
    base_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+){1,2}).*/\1/p' "$IOS_DIR/Config/Shared.xcconfig" 2>/dev/null | head -1)"
  fi
  if [[ "$base_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    BETA_MARKETING_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$(( BASH_REMATCH[3] + 1 ))"
  elif [[ "$base_version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    BETA_MARKETING_VERSION="${BASH_REMATCH[1]}.$(( BASH_REMATCH[2] + 1 )).0"
  fi
  if [[ -n "$BETA_MARKETING_VERSION" ]]; then
    MARKETING_VERSION_ARGS=( "MARKETING_VERSION=$BETA_MARKETING_VERSION" )
    echo "auto-version: stamping beta MARKETING_VERSION=$BETA_MARKETING_VERSION (last release base ${base_version:-unknown})" >&2
  else
    # Fail closed: --auto-version disables the changelog version guard, so if we
    # cannot compute a stamp we must not silently upload the un-bumped checked-in
    # version with the guard off.
    echo "error: --auto-version could not compute a beta version (base '${base_version:-}'); refusing to upload with the version guard disabled and no stamp. Ensure an ios-v<X.Y.Z> tag or a valid MARKETING_VERSION in ios/Config/Shared.xcconfig." >&2
    exit 1
  fi
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
    # Release entitlements to preserve during App Store Connect export. An
    # unsigned archive exports with only the profile baseline and drops
    # aps-environment, which the gate below correctly refuses to upload.
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
      ${MARKETING_VERSION_ARGS[@]+"${MARKETING_VERSION_ARGS[@]}"} \
      CODE_SIGN_STYLE=Automatic \
      CODE_SIGN_ENTITLEMENTS="Config/cmux-release.entitlements" \
      CODE_SIGN_IDENTITY="Apple Distribution" \
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

ARCHIVE_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
if [[ -n "$ARCHIVE_BUNDLE_IDENTIFIER" && "$ARCHIVE_BUNDLE_IDENTIFIER" != "$PRODUCT_BUNDLE_IDENTIFIER" ]]; then
  echo "error: archive bundle id is '$ARCHIVE_BUNDLE_IDENTIFIER' but lane '$LANE' requires '$PRODUCT_BUNDLE_IDENTIFIER'. Re-archive for the selected lane." >&2
  exit 1
fi

# Now that the archive exists, its marketing version (CFBundleShortVersionString)
# is the version testers will see. Re-run the notes preflight WITH that version so
# a deterministic mismatch (changelog top is 1.0.3 but the archived build is 1.0.0)
# fails BEFORE the export/upload, not after (when the notes step is non-fatal and
# would just ship an opaque build). Skipped for --export-only / --skip-notes. If the
# archive's version is unreadable, the version-match guard simply does not run.
# Skipped in range-notes mode: the notes come from the commit range, not the
# changelog, and --auto-version intentionally stamps a version the changelog would
# not match.
if [[ "$LANE" == "beta" && "$EXPORT_ONLY" -ne 1 && "$SKIP_NOTES" -ne 1 && "$RANGE_NOTES_MODE" -ne 1 ]]; then
  ARCHIVE_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
  if [[ "$ARCHIVE_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    if ! "$SCRIPT_DIR/set-testflight-notes.sh" --validate-only \
        --audience "$NOTES_AUDIENCE" --expect-marketing-version "$ARCHIVE_MARKETING_VERSION"; then
      echo "error: ios/CHANGELOG.md top entry does not match the archived marketing version $ARCHIVE_MARKETING_VERSION (see above); refusing to upload a build whose What to Test notes would be for the wrong version. Update ios/CHANGELOG.md, or pass --skip-notes." >&2
      exit 1
    fi
  else
    echo "note: could not read the archive's marketing version; deferring the notes version-match guard to the post-upload step" >&2
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
  /usr/libexec/PlistBuddy -c "Merge $PROFILE_ENTITLEMENTS" "$MERGED_ENTITLEMENTS" >/dev/null || true
  /usr/libexec/PlistBuddy -c "Merge $RELEASE_ENTITLEMENTS" "$MERGED_ENTITLEMENTS" >/dev/null || true
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

echo "IPA_PATH=$IPA_PATH"

if [[ "$LANE" == "appstore" ]]; then
  if ! verify_app_store_ipa_has_no_external_purchase_links "$IPA_PATH"; then
    exit 1
  fi
  echo "App Store IPA verified to omit external purchase/enrollment links: $IPA_PATH"
fi

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
  NOTES_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
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
# MARKETING_VERSION. This is fatal: a red CI/upload is preferable to claiming
# the external lane tracked main when the build never reached the founders lane.
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
