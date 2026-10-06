#!/usr/bin/env bash
# Runs one package test filter (red/green evidence): suite-runner.sh FILTER
set -uo pipefail
./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext "$1" 2>&1 \
  | grep -E "✘|Test run with|error:|Expectation failed|passed  |failed " | grep -v " started" | head -60 || true
tail -n 12 /dev/null
