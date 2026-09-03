#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_runner="$repo_root/scripts/ci/run-swift-testing-suites.sh"
packages=(
  CmuxLiteProtocol
  CmuxLiteSession
  CmuxLiteTransport
  CmuxLiteIroh
)

for package in "${packages[@]}"; do
  "$test_runner" \
    "$repo_root/experiments/cmux-lite-ios/Packages/$package"
done
