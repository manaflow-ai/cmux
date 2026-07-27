#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! grep -Fq 'max_attempts="${CMUX_APP_HOST_XCODEBUILD_ATTEMPTS:-3}"' "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh"; then
  echo "FAIL: app-host xcodebuild default attempts must stay at 3"
  exit 1
fi

echo "PASS: app-host xcodebuild default attempts are guarded"
