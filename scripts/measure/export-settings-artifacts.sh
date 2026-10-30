#!/usr/bin/env bash
set -euo pipefail
# Build with the CI's pinned Xcode (scripts/ci/xcode-pins.txt, or CMUX_CI_XCODE_APP), as the
# package-test lane does, not the mini's default: a newer default Xcode can fail to compile test
# targets these generators never run.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_env="$(mktemp)"
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
  rm -f "$xcode_env"
  test -n "$DEVELOPER_DIR"
  export DEVELOPER_DIR
fi
echo "Xcode: $DEVELOPER_DIR"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=export-settings
exec "$script_dir/../ci/run-swift-testing-suites.sh" Packages/macOS/CmuxNext
