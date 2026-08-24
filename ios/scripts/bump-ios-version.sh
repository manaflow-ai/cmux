#!/usr/bin/env bash
set -euo pipefail

# Bump the iOS app's lane-specific marketing version
# (CFBundleShortVersionString) in ios/Config/Shared.xcconfig. Beta and App Store
# versions are intentionally independent: beta can stay on an already-approved
# TestFlight version while production starts at its own App Store version.
# CFBundleVersion remains the monotonic build id stamped by
# ios/scripts/upload-testflight.sh on upload.
#
# Usage:
#   ios/scripts/bump-ios-version.sh                    # Bump beta patch
#   ios/scripts/bump-ios-version.sh --lane appstore    # Bump App Store patch
#   ios/scripts/bump-ios-version.sh 1.0.1 --lane appstore
#   ios/scripts/bump-ios-version.sh minor              # Bump beta minor
#   ios/scripts/bump-ios-version.sh --lane beta 1.2.3  # Set beta version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XCCONFIG="$IOS_DIR/Config/Shared.xcconfig"
TMP_XCCONFIG=""

cleanup_tmp() {
  if [[ -n "$TMP_XCCONFIG" && -f "$TMP_XCCONFIG" ]]; then
    rm -f "$TMP_XCCONFIG"
  fi
}
trap cleanup_tmp EXIT

if [[ ! -f "$XCCONFIG" ]]; then
  echo "Error: $XCCONFIG not found." >&2
  exit 1
fi

usage() {
  echo "Usage: $0 [--lane beta|appstore] [version|patch|minor|major]" >&2
  echo "       $0 [version|patch|minor|major] [--lane beta|appstore]" >&2
}

read_xcconfig_setting() {
  local key="$1"
  sed -nE "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\\1/p" "$XCCONFIG" | tail -n 1
}

LANE="beta"
LANE_SET=0
VERSION_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)
      if [[ "$LANE_SET" -eq 1 || -z "${2:-}" || "${2:-}" == --* ]]; then
        usage
        exit 1
      fi
      LANE="$2"
      LANE_SET=1
      shift 2
      ;;
    --lane=*)
      if [[ "$LANE_SET" -eq 1 || -z "${1#--lane=}" ]]; then
        usage
        exit 1
      fi
      LANE="${1#--lane=}"
      LANE_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 1
      ;;
    *)
      if [[ -n "$VERSION_ARG" ]]; then
        usage
        exit 1
      fi
      VERSION_ARG="$1"
      shift
      ;;
  esac
done

case "$LANE" in
  beta)
    KEY="CMUX_IOS_BETA_MARKETING_VERSION"
    DISPLAY_LANE="beta"
    ;;
  appstore)
    KEY="CMUX_IOS_APPSTORE_MARKETING_VERSION"
    DISPLAY_LANE="App Store"
    ;;
  *)
    usage
    exit 1
    ;;
esac

CURRENT_MARKETING="$(read_xcconfig_setting "$KEY")"
if [[ -z "$CURRENT_MARKETING" ]]; then
  echo "Error: could not read the configured $DISPLAY_LANE marketing version from $XCCONFIG" >&2
  exit 1
fi

echo "Current $DISPLAY_LANE marketing version: $CURRENT_MARKETING"

# Normalize to X.Y.Z (tolerate a bare "1.0" by treating the missing patch as 0).
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_MARKETING"
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

if [[ -z "$VERSION_ARG" ]] || [[ "$VERSION_ARG" == "patch" ]]; then
  NEW_MARKETING="$MAJOR.$MINOR.$((PATCH + 1))"
elif [[ "$VERSION_ARG" == "minor" ]]; then
  NEW_MARKETING="$MAJOR.$((MINOR + 1)).0"
elif [[ "$VERSION_ARG" == "major" ]]; then
  NEW_MARKETING="$((MAJOR + 1)).0.0"
elif [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW_MARKETING="$VERSION_ARG"
else
  usage
  echo "  version: specific version like 1.2.3" >&2
  echo "  patch: bump patch version (default)" >&2
  echo "  minor: bump minor version" >&2
  echo "  major: bump major version" >&2
  exit 1
fi

echo "New $DISPLAY_LANE marketing version: $NEW_MARKETING"

TMP_XCCONFIG="$(mktemp "${XCCONFIG}.XXXXXX")"
sed -E "s/^([[:space:]]*$KEY[[:space:]]*=[[:space:]]*).*/\\1$NEW_MARKETING/" "$XCCONFIG" > "$TMP_XCCONFIG"
mv "$TMP_XCCONFIG" "$XCCONFIG"

UPDATED_MARKETING="$(read_xcconfig_setting "$KEY")"
if [[ "$UPDATED_MARKETING" != "$NEW_MARKETING" ]]; then
  echo "Error: version update failed!" >&2
  exit 1
fi

echo "Updated $XCCONFIG successfully."
