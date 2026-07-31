#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
PROJECT_FILE="$FIXTURE_DIR/project.pbxproj"

write_versions() {
  printf 'MARKETING_VERSION = %s;\nMARKETING_VERSION = %s;\n' "$1" "$2" > "$PROJECT_FILE"
}

write_versions 0.64.20 0.64.20
CMUX_PROJECT_FILE="$PROJECT_FILE" "$ROOT_DIR/scripts/validate-release-version.sh" v0.64.20 >/dev/null

for invalid_tag in v0.64.19 v0.64.20-rc.1 nightly release-0.64.20; do
  if CMUX_PROJECT_FILE="$PROJECT_FILE" "$ROOT_DIR/scripts/validate-release-version.sh" "$invalid_tag" >/dev/null 2>&1; then
    echo "FAIL: accepted invalid or mismatched stable tag $invalid_tag" >&2
    exit 1
  fi
done

write_versions 0.64.20 0.64.21
if CMUX_PROJECT_FILE="$PROJECT_FILE" "$ROOT_DIR/scripts/validate-release-version.sh" v0.64.20 >/dev/null 2>&1; then
  echo "FAIL: accepted inconsistent MARKETING_VERSION values" >&2
  exit 1
fi

echo "PASS: stable release tags must exactly match one project marketing version"
