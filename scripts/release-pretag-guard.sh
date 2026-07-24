#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running release pre-tag checks..."
PROJECT_VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$ROOT_DIR/cmux.xcodeproj/project.pbxproj" | head -n1)"
"$ROOT_DIR/scripts/validate-release-version.sh" "${1:-v$PROJECT_VERSION}"
CMUX_SPARKLE_MONOTONIC_STRICT=1 "$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
echo "Release pre-tag checks passed."
