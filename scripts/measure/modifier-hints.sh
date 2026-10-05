#!/usr/bin/env bash
# Focused modifier-hold verification, admitted by the fleet controller.
set -euo pipefail
trap 'status=$?; if (( status != 0 )); then echo "Modifier hint verification failed (exit $status). Fix the reported compile/test failure and resubmit the pushed SHA through cmux-ci; see https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md#ci-on-main" >&2; fi' EXIT
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)" scripts/download-prebuilt-ghosttykit.sh
scripts/cmux-next/prefix-ghosttykit-archives.sh GhosttyKit.xcframework
root="$(pwd)"
cd Packages/macOS/CmuxNext
"$root/scripts/cmux-next/swift-test-with-hang-sampler.sh" -j 4 -Xlinker -lc++ \
  --filter 'ModifierHoldHintsTests|ModifierHoldHintsSettingTests|SettingsSchemaExportTests'
