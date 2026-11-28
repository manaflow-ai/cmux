#!/usr/bin/env bash
# cmux-next.yml swift-test: "Run package tests (changed suites first, then selected targets)", run from
# Packages/macOS/CmuxNext (the step's working-directory).
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
echo "Test targets: $SWIFT_TARGETS"
# Why: docs/ci/cmux-next-workflow-notes/2026-11-24-swift-test-7.md
deadline=$(( $(date +%s) + 2280 ))
# Why: docs/ci/cmux-next-workflow-notes/2026-11-24-swift-test-8.md
heavy_skip=()
[[ -z "$CMUX_NEXT_MAIN_THREAD_HEAVY" ]] || heavy_skip=(--skip "$CMUX_NEXT_MAIN_THREAD_HEAVY")
priority_skip=()
priority_status=0
if [[ -n "$SWIFT_PRIORITY_FILTER" ]]; then
  echo "Changed Swift suites first: $SWIFT_PRIORITY_FILTER"
  if ../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build --no-parallel --filter "$SWIFT_PRIORITY_FILTER" \
      ${heavy_skip[@]+"${heavy_skip[@]}"}; then
    :
  else
    priority_status=$?
    echo "Changed Swift suite shard failed with status $priority_status; continuing with the selected target pass" >&2
  fi
  priority_skip=(--skip "$SWIFT_PRIORITY_FILTER")
fi
# Why: docs/ci/cmux-next-workflow-notes.md#note-402
tree_path="$(../../../scripts/cmux-next/pin-cmux-tui.sh path 2>/dev/null)" || tree_path=""
if [[ -n "$tree_path" && -x "$tree_path" ]]; then
  echo "Broad pass same-tree cmux-tui: $tree_path"
else
  echo "Broad pass same-tree cmux-tui: not here yet; the live-daemon suites skip"
  tree_path=/dev/null/no-same-tree-here
fi
broad_status=0
if CMUX_NEXT_TUI_TREE_PATH="$tree_path" python3 ../../../scripts/cmux-next/swift-test-shards.py run --targets "$SWIFT_TARGETS" \
    --exclude CmuxNextControlTests --wrapper ../../../scripts/cmux-next/swift-test-with-hang-sampler.sh \
    --deadline "$deadline" --spill "$RUNNER_TEMP/cmux-next-spilled-shards.json" \
    -- ${priority_skip[@]+"${priority_skip[@]}"} --skip BranchStateResourcesTests \
    --skip CloudBringBackTests --skip CommitBoundaryAppKitTests ${heavy_skip[@]+"${heavy_skip[@]}"}; then
  :
else
  broad_status=$?
fi
(( priority_status == 0 && broad_status == 0 ))
