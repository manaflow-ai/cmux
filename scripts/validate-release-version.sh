#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${CMUX_PROJECT_FILE:-$ROOT_DIR/cmux.xcodeproj/project.pbxproj}"
TAG="${1:-}"

if [[ ! "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "FAIL: stable release tag must match v<major>.<minor>.<patch> exactly (got '$TAG')" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "FAIL: Xcode project not found at $PROJECT_FILE" >&2
  exit 1
fi

PROJECT_VERSIONS="$(
  sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJECT_FILE" \
    | sort -u
)"
VERSION_COUNT="$(printf '%s\n' "$PROJECT_VERSIONS" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$VERSION_COUNT" != "1" ]]; then
  echo "FAIL: MARKETING_VERSION values are missing or inconsistent:" >&2
  printf '%s\n' "$PROJECT_VERSIONS" >&2
  exit 1
fi

PROJECT_VERSION="$(printf '%s\n' "$PROJECT_VERSIONS" | head -n1)"
TAG_VERSION="${TAG#v}"
if [[ "$TAG_VERSION" != "$PROJECT_VERSION" ]]; then
  echo "FAIL: release tag $TAG does not match MARKETING_VERSION $PROJECT_VERSION" >&2
  exit 1
fi

echo "PASS: release tag $TAG matches MARKETING_VERSION $PROJECT_VERSION"
