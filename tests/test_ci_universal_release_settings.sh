#!/usr/bin/env bash
# Regression test for universal GhosttyKit and Release build settings.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for file in \
  "$ROOT_DIR/.github/workflows/build-ghosttykit.yml" \
  "$ROOT_DIR/scripts/setup.sh" \
  "$ROOT_DIR/scripts/build-sign-upload.sh"
do
  if ! grep -Fq -- '-Dxcframework-target=universal' "$file"; then
    echo "FAIL: $file must build GhosttyKit with -Dxcframework-target=universal"
    exit 1
  fi
done

if ! awk '
  /\/\* Release \*\// { in_release=1; next }
  in_release && /ONLY_ACTIVE_ARCH = YES;/ { saw_yes=1 }
  in_release && /ONLY_ACTIVE_ARCH = NO;/ { saw_no=1 }
  in_release && /name = Release;/ { in_release=0 }
  END { exit !(saw_no && !saw_yes) }
' "$ROOT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"; then
  echo "FAIL: Release configurations in project.pbxproj must use ONLY_ACTIVE_ARCH = NO"
  exit 1
fi

echo "PASS: GhosttyKit builds universal and Release configs disable ONLY_ACTIVE_ARCH"
