#!/usr/bin/env bash
set -euo pipefail

mode="${1:-app}"
if [[ "$mode" != "app" && "$mode" != "tests" ]]; then
  echo "usage: $0 [app|tests]" >&2
  exit 2
fi

paths=(
  cmux.xcodeproj/project.pbxproj
  cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  cmux-Bridging-Header.h
  CLI
  Packages
  Resources
  Sources
)

if [[ "$mode" == "tests" ]]; then
  paths+=(cmuxTests)
fi

{
  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
  fi

  git ls-files -z -- "${paths[@]}" |
    sort -z |
    xargs -0 shasum -a 256
} | shasum -a 256 | awk '{print $1}'
