#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
timeout="$(
  awk '
    /^  release-build:/ { in_release_build = 1; next }
    in_release_build && /^  [A-Za-z0-9_-]+:/ { exit }
    in_release_build && /timeout-minutes:/ { print $2; exit }
  ' "$ROOT_DIR/.github/workflows/ci.yml"
)"

if [ -z "$timeout" ]; then
  echo "FAIL: release-build timeout-minutes not found"
  exit 1
fi

if [ "$timeout" -lt 40 ]; then
  echo "FAIL: release-build timeout-minutes must be at least 40, got $timeout"
  exit 1
fi

echo "PASS: release-build timeout allows slow artifact upload"
