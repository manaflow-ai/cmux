#!/usr/bin/env bash
set -euo pipefail

SCHEME_FILE="cmux.xcodeproj/xcshareddata/xcschemes/cmux.xcscheme"
UNIT_SCHEME_FILE="cmux.xcodeproj/xcshareddata/xcschemes/cmux-unit.xcscheme"

if [ ! -f "$SCHEME_FILE" ]; then
  echo "FAIL: Missing scheme file at $SCHEME_FILE" >&2
  exit 1
fi

if ! grep -q '<TestAction buildConfiguration="Debug"' "$SCHEME_FILE"; then
  echo "FAIL: cmux scheme TestAction must use Debug build configuration for UI test setup hooks" >&2
  exit 1
fi

if [ ! -f "$UNIT_SCHEME_FILE" ]; then
  echo "FAIL: Missing scheme file at $UNIT_SCHEME_FILE" >&2
  exit 1
fi

launch_action="$(sed -n '/<LaunchAction /,/<\/LaunchAction>/p' "$UNIT_SCHEME_FILE")"
if ! grep -q '<EnvironmentVariable key="CMUX_UI_TEST_PROCESS" value="1" isEnabled="YES"/>' <<<"$launch_action"; then
  echo "FAIL: cmux-unit Run action must mark its app host as an XCTest process before Sentry startup" >&2
  exit 1
fi

echo "PASS: cmux scheme TestAction uses Debug"
echo "PASS: cmux-unit app host has an explicit XCTest launch marker"
