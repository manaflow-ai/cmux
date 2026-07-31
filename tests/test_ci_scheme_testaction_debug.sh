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
  if ! grep -q '<TestAction .*shouldUseLaunchSchemeArgsEnv="YES">' "$scheme_file"; then
    echo "FAIL: $scheme TestAction must preserve the launch environment" >&2
    exit 1
  fi
done

for scheme in cmux-ci cmux-unit; do
  scheme_file="cmux.xcodeproj/xcshareddata/xcschemes/${scheme}.xcscheme"
  if ! sed -n '/<LaunchAction /,/<\/LaunchAction>/p' "$scheme_file" \
    | grep -q 'key="CMUX_XCTEST_APP_HOST" value="1" isEnabled="YES"'; then
    echo "FAIL: $scheme LaunchAction must mark its app host as XCTest" >&2
    exit 1
  fi
done

if sed -n '/<LaunchAction /,/<\/LaunchAction>/p' "$SCHEME_FILE" \
  | grep -q 'key="CMUX_XCTEST_APP_HOST"'; then
  echo "FAIL: cmux Release LaunchAction must not disable Sentry" >&2
  exit 1
fi

echo "PASS: cmux scheme TestAction uses Debug"
