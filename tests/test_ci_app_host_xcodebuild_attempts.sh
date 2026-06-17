#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! grep -Fq 'max_attempts="${CMUX_APP_HOST_XCODEBUILD_ATTEMPTS:-3}"' "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh"; then
  echo "FAIL: app-host xcodebuild default attempts must stay at 3"
  exit 1
fi

if ! grep -Fq 'lock_dir="${CMUX_APP_HOST_XCODEBUILD_LOCK_DIR:-/tmp/cmux-ci-app-host-xcodebuild.lock}"' "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh"; then
  echo "FAIL: app-host xcodebuild must use a host-global lock by default"
  exit 1
fi

echo "PASS: app-host xcodebuild default attempts and host lock are guarded"
