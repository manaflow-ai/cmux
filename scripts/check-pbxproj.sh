#!/usr/bin/env bash
# CI guard for cmux.xcodeproj/project.pbxproj.
# Fails when:
#   - objectVersion drifts from the pinned value (Xcode major leak)
#   - the file is not normalized (someone bypassed the pre-commit hook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$REPO_ROOT/cmux.xcodeproj/project.pbxproj"
XCODE_VERSION_FILE="$REPO_ROOT/.xcode-version"

# Source of truth for the team's Xcode pin: .xcode-version at the repo root.
# When the team bumps to a new Xcode major, edit that one file and update
# the case below if Apple bumped objectVersion in the new major.
XCODE_VERSION="$(tr -d '[:space:]' < "$XCODE_VERSION_FILE")"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
case "$XCODE_MAJOR" in
    26)  EXPECTED_OBJECT_VERSION=60 ;;
    *)   echo "::error::Unknown Xcode major '$XCODE_MAJOR' in .xcode-version ($XCODE_VERSION). Add a case in scripts/check-pbxproj.sh." >&2; exit 1 ;;
esac

actual="$(grep -E '^[[:space:]]*objectVersion = [0-9]+;' "$PBXPROJ" | head -1 | grep -oE '[0-9]+')"
if [[ "$actual" != "$EXPECTED_OBJECT_VERSION" ]]; then
    echo "::error file=cmux.xcodeproj/project.pbxproj,line=6::objectVersion is $actual, expected $EXPECTED_OBJECT_VERSION for Xcode $XCODE_VERSION." >&2
    echo "The team is pinned to Xcode $XCODE_VERSION (see .xcode-version)." >&2
    echo "If you intended to bump the pin, edit .xcode-version and add a case in scripts/check-pbxproj.sh." >&2
    exit 1
fi

python3 "$SCRIPT_DIR/normalize-pbxproj.py" --check "$PBXPROJ"
