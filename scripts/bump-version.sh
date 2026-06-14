#!/usr/bin/env bash
set -euo pipefail

# Stamp MARKETING_VERSION and CURRENT_PROJECT_VERSION from a YYYY.MM.DD.HHMM
# timestamp. The fork is on a date-based versioning scheme:
#
#   canonical stamp         = YYYY.MM.DD.HHMM   (America/Vancouver)
#   MARKETING_VERSION       = YYYY.MM.DD        (CFBundleShortVersionString)
#   CURRENT_PROJECT_VERSION = HHMM              (CFBundleVersion). The macOS
#     About box then shows "YYYY.MM.DD (HHMM)" — e.g. "2026.06.14 (1324)" —
#     matching bootstrapmate-macintosh's MARKETING_VERSION/BUILD_NUMBER split.
#
# Usage:
#   ./scripts/bump-version.sh                    # stamp now
#   ./scripts/bump-version.sh 2026.05.25.1956    # stamp an explicit value

PROJECT_FILE="GhosttyTabs.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from repo root." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  STAMP=$(TZ=America/Vancouver date +'%Y.%m.%d.%H%M')
elif [[ "$1" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$ ]]; then
  STAMP="$1"
else
  echo "Usage: $0 [YYYY.MM.DD.HHMM]" >&2
  exit 1
fi

NEW_MARKETING="${STAMP%.*}"
NEW_BUILD="${STAMP##*.}"

CURRENT_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

echo "Current: MARKETING_VERSION=$CURRENT_MARKETING, CURRENT_PROJECT_VERSION=$CURRENT_BUILD"
echo "New:     MARKETING_VERSION=$NEW_MARKETING, CURRENT_PROJECT_VERSION=$NEW_BUILD"

sed -i '' "s/MARKETING_VERSION = $CURRENT_MARKETING;/MARKETING_VERSION = $NEW_MARKETING;/g" "$PROJECT_FILE"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PROJECT_FILE"

UPDATED_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
UPDATED_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

MARKETING_UNIQ=$(grep 'MARKETING_VERSION = ' "$PROJECT_FILE" | sort -u | wc -l | tr -d ' ')
BUILD_UNIQ=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u | wc -l | tr -d ' ')

if [[ "$UPDATED_MARKETING" != "$NEW_MARKETING" || "$UPDATED_BUILD" != "$NEW_BUILD" ]]; then
  echo "Error: version update did not take effect." >&2
  exit 1
fi
if [[ "$MARKETING_UNIQ" != "1" || "$BUILD_UNIQ" != "1" ]]; then
  echo "Error: project file has mixed version values after stamping." >&2
  exit 1
fi

echo "Stamped $PROJECT_FILE: $NEW_MARKETING / $NEW_BUILD"
