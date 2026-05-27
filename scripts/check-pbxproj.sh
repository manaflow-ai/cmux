#!/usr/bin/env bash
# CI guard for cmux.xcodeproj/project.pbxproj.
# Fails when:
#   - objectVersion drifts from the pinned value (Xcode major leak)
#   - the file is not normalized (someone bypassed the pre-commit hook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$REPO_ROOT/cmux.xcodeproj/project.pbxproj"

EXPECTED_OBJECT_VERSION=60

actual="$(grep -E '^[[:space:]]*objectVersion = [0-9]+;' "$PBXPROJ" | head -1 | grep -oE '[0-9]+')"
if [[ "$actual" != "$EXPECTED_OBJECT_VERSION" ]]; then
    echo "::error file=cmux.xcodeproj/project.pbxproj,line=6::objectVersion is $actual, expected $EXPECTED_OBJECT_VERSION." >&2
    echo "The team is pinned to Xcode 26 (objectVersion $EXPECTED_OBJECT_VERSION)." >&2
    echo "If you intended to bump the pin, update EXPECTED_OBJECT_VERSION in scripts/check-pbxproj.sh and CLAUDE.md." >&2
    exit 1
fi

python3 "$SCRIPT_DIR/normalize-pbxproj.py" --check
