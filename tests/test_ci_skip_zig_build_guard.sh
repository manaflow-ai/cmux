#!/usr/bin/env bash
# Regression test to keep CI macOS jobs from live-building the Ghostty helper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

check_job() {
  local job_name="$1"
  if ! awk -v job_name="$job_name" '
    $0 == "  " job_name ":" {
      in_job = 1
      next
    }
    in_job && $0 ~ /^  [^ ]/ {
      exit found ? 0 : 1
    }
    in_job && $0 ~ /CMUX_SKIP_ZIG_BUILD: 1/ {
      found = 1
    }
    END {
      if (!in_job || !found) {
        exit 1
      }
    }
  ' "$WORKFLOW_FILE"; then
    echo "FAIL: $job_name in ci.yml must set CMUX_SKIP_ZIG_BUILD: 1" >&2
    exit 1
  fi
}

check_job "tests"
check_job "tests-build-and-lag"
check_job "ui-regressions"

echo "PASS: CI macOS jobs skip zig Ghostty helper builds"
