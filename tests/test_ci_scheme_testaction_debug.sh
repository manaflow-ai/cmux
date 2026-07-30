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

for scheme_name in cmux-unit cmux-ci; do
  unit_scheme_file="cmux.xcodeproj/xcshareddata/xcschemes/${scheme_name}.xcscheme"
  if ! grep -Fq '<EnvironmentVariable key="CMUX_TEST_PROCESS" value="1" isEnabled="YES"/>' "$unit_scheme_file"; then
    echo "FAIL: ${scheme_name} scheme must identify its app host with CMUX_TEST_PROCESS=1" >&2
    exit 1
  fi
done

echo "PASS: cmux scheme TestAction uses Debug"
