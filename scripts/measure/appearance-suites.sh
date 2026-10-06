#!/usr/bin/env bash
# Settings, theme and launch appearance suites (green evidence).
set -uo pipefail
./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext "LaunchAppearanceTests|Settings|Theme|WindowBackground" > /tmp/appearance-suites.log 2>&1; echo "lane exit $?"
grep -E "✘|Test run with|error:" /tmp/appearance-suites.log | grep -v " started" | head -40
tail -n 15 /tmp/appearance-suites.log
