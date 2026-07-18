#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/nightly-perf-benchmark.yml"
RUNNER="$ROOT_DIR/scripts/ci/benchmark-nightly-build.sh"

if [ ! -f "$WORKFLOW" ] || [ ! -x "$RUNNER" ]; then
  echo "FAIL: nightly performance benchmark workflow and executable runner are required" >&2
  exit 1
fi

for scenario in universal-wmo universal-singlefile arm64-wmo x86_64-wmo; do
  if ! grep -Fq "$scenario" "$WORKFLOW"; then
    echo "FAIL: missing benchmark scenario: $scenario" >&2
    exit 1
  fi
done

for requirement in \
  'CMUX_CI_XCODE_APP_MACOS_26' \
  'blacksmith-6vcpu-macos-26' \
  './scripts/select-ci-xcode.sh' \
  './scripts/download-prebuilt-ghosttykit.sh' \
  './scripts/ci/benchmark-nightly-build.sh' \
  'actions/upload-artifact@'; do
  if ! grep -Fq "$requirement" "$WORKFLOW"; then
    echo "FAIL: benchmark workflow missing: $requirement" >&2
    exit 1
  fi
done

for requirement in \
  'SWIFT_COMPILATION_MODE=' \
  'SWIFT_OPTIMIZATION_LEVEL=-O' \
  'COMPILATION_CACHE_ENABLE_CACHING=YES' \
  'COMPILER_INDEX_STORE_ENABLE=NO' \
  'CODE_SIGNING_ALLOWED=NO' \
  'lipo' \
  'dwarfdump --uuid' \
  'strip-release-bundle.sh' \
  'smoke-launch-macos-app.sh'; do
  if ! grep -Fq "$requirement" "$RUNNER"; then
    echo "FAIL: benchmark runner missing safety or measurement check: $requirement" >&2
    exit 1
  fi
done

echo "PASS: nightly performance benchmark preserves release constraints"
