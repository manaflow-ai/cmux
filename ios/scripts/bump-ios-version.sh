#!/usr/bin/env bash
set -euo pipefail

# Bump the iOS app's MARKETING_VERSION (CFBundleShortVersionString) in
# ios/Config/Shared.xcconfig. This is the user-visible, tellable version testers
# report. It is bumped MANUALLY on release (semver, human-meaningful) — unlike
# CFBundleVersion (the monotonic build id), which ios/scripts/upload-testflight.sh
# stamps per upload as a UTC timestamp. Keeping the marketing bump manual avoids
# a CI commit-back loop on every merge; the patch number moves only when you cut
# a build worth reporting.
#
# Usage:
#   ios/scripts/bump-ios-version.sh           # Bump patch (1.0.0 -> 1.0.1, default)
#   ios/scripts/bump-ios-version.sh patch     # Bump patch (1.0.0 -> 1.0.1)
#   ios/scripts/bump-ios-version.sh minor     # Bump minor (1.0.0 -> 1.1.0)
#   ios/scripts/bump-ios-version.sh major     # Bump major (1.0.0 -> 2.0.0)
#   ios/scripts/bump-ios-version.sh 1.2.3     # Set a specific version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XCCONFIG="$IOS_DIR/Config/Shared.xcconfig"

if [[ ! -f "$XCCONFIG" ]]; then
  echo "Error: $XCCONFIG not found." >&2
  exit 1
fi

CURRENT_MARKETING="$(grep -m1 '^MARKETING_VERSION = ' "$XCCONFIG" | sed 's/^MARKETING_VERSION = //')"
if [[ -z "$CURRENT_MARKETING" ]]; then
  echo "Error: could not read MARKETING_VERSION from $XCCONFIG" >&2
  exit 1
fi

echo "Current: MARKETING_VERSION=$CURRENT_MARKETING"

# Normalize to X.Y.Z (tolerate a bare "1.0" by treating the missing patch as 0).
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_MARKETING"
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

if [[ $# -eq 0 ]] || [[ "$1" == "patch" ]]; then
  NEW_MARKETING="$MAJOR.$MINOR.$((PATCH + 1))"
elif [[ "$1" == "minor" ]]; then
  NEW_MARKETING="$MAJOR.$((MINOR + 1)).0"
elif [[ "$1" == "major" ]]; then
  NEW_MARKETING="$((MAJOR + 1)).0.0"
elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW_MARKETING="$1"
else
  echo "Usage: $0 [version|patch|minor|major]" >&2
  echo "  version: specific version like 1.2.3" >&2
  echo "  patch: bump patch version (default)" >&2
  echo "  minor: bump minor version" >&2
  echo "  major: bump major version" >&2
  exit 1
fi

echo "New:     MARKETING_VERSION=$NEW_MARKETING"

sed -i '' "s/^MARKETING_VERSION = $CURRENT_MARKETING\$/MARKETING_VERSION = $NEW_MARKETING/" "$XCCONFIG"

UPDATED_MARKETING="$(grep -m1 '^MARKETING_VERSION = ' "$XCCONFIG" | sed 's/^MARKETING_VERSION = //')"
if [[ "$UPDATED_MARKETING" != "$NEW_MARKETING" ]]; then
  echo "Error: version update failed!" >&2
  exit 1
fi

echo "Updated $XCCONFIG successfully."
