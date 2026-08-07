#!/usr/bin/env bash
# CI guard for cmux.xcodeproj/project.pbxproj.
# Fails when:
#   - objectVersion drifts from the pinned value (Xcode major leak)
#   - a PBX object identifier has more than one definition
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

# Exercise the duplicate guard with one of this project's existing 25-character
# identifiers. A validator limited to Xcode's conventional 24-character UUIDs
# silently accepts this damaged fixture.
duplicate_fixture_dir="$(mktemp -d)"
trap 'rm -rf "$duplicate_fixture_dir"' EXIT
duplicate_fixture="$duplicate_fixture_dir/duplicate.pbxproj"
printf '\t\t%s\n' \
    'CA11E4D0FA017DE500000B101 /* First */ = {isa = PBXBuildFile; };' \
    'CA11E4D0FA017DE500000B101 /* Second */ = {isa = PBXFileReference; };' \
    > "$duplicate_fixture"
if python3 "$SCRIPT_DIR/normalize-pbxproj.py" --check "$duplicate_fixture" \
    >/dev/null 2>&1; then
    echo "::error::normalize-pbxproj accepted a duplicate 25-character object identifier." >&2
    exit 1
fi
