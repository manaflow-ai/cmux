#!/usr/bin/env bash
# Opt-in classic upgrade measurements, separate from PR correctness checks:
# cmux-ci run --class exclusive --script scripts/measure/classic-upgrade.sh --ref SHA
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Refuse a skipped simulation: measurements require this source tree's daemon.
export CMUX_TUI_TREE_WAIT_SECONDS=0
bash scripts/cmux-next/pin-cmux-tui.sh fetch
CMUX_NEXT_TUI_TREE_PATH="$(bash scripts/cmux-next/pin-cmux-tui.sh path)"
export CMUX_NEXT_TUI_TREE_PATH
test -x "$CMUX_NEXT_TUI_TREE_PATH"

export CMUX_CLASSIC_UPGRADE_PERF=1
export CMUX_CI_XCODE_APP=/Applications/Xcode_26.6.app
exec bash scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext \
  ClassicUpgradeSimulationTests/theFirstLaunchBringsEverythingOnce,ClassicUpgradeSimulationPerfTests
