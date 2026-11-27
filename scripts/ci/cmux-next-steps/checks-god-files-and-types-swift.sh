#!/usr/bin/env bash
# cmux-next.yml checks: "God files and types (Swift)".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
base=()
[[ "$EVENT_NAME" == pull_request ]] && base=(--base HEAD^1)
set -o pipefail
mkdir -p "$RUNNER_TEMP/ratchet-debt"
# Why: 2026-11-24-checks-32.md
rc=0
scripts/cmux-next/check-no-godfiles.sh --only swift ${base[@]+"${base[@]}"} "$GITHUB_WORKSPACE/Packages/macOS/CmuxNext" | tee "$RUNNER_TEMP/ratchet-debt/godfiles-swift.log" || rc=$?
if (( rc == 1 )); then
  echo "::warning title=god files (swift)::over the hard ceiling; warn-only (Lawrence 2026-10-10), see this step's log"
elif (( rc != 0 )); then
  exit "$rc"
fi
