#!/usr/bin/env bash
set -euo pipefail

SCHEME_FILE="cmux.xcodeproj/xcshareddata/xcschemes/cmux.xcscheme"

if [ ! -f "$SCHEME_FILE" ]; then
  echo "FAIL: Missing scheme file at $SCHEME_FILE" >&2
  exit 1
fi

if ! grep -q '<TestAction buildConfiguration="Debug"' "$SCHEME_FILE"; then
  echo "FAIL: cmux scheme TestAction must use Debug build configuration for UI test setup hooks" >&2
  exit 1
fi

for scheme in cmux cmux-ci cmux-unit; do
  scheme_file="cmux.xcodeproj/xcshareddata/xcschemes/${scheme}.xcscheme"
  if ! grep -q 'key="CMUX_XCTEST_APP_HOST" value="1" isEnabled="YES"' "$scheme_file"; then
    echo "FAIL: $scheme TestAction must mark its app host as XCTest" >&2
    exit 1
  fi
done

echo "PASS: cmux scheme TestAction uses Debug"
