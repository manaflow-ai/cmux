#!/usr/bin/env bash
# cmux-next.yml swift-canary: "Type-check changed CmuxNext targets".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
read -r -a targets <<< "$SWIFT_CANARY_TARGETS"
((${#targets[@]} > 0))
started=$(date +%s)
for target in "${targets[@]}"; do
  echo "Canary target: $target"
  bash ../../../scripts/ci/github-egress-run.sh swift build --configuration debug --target "$target"
done
elapsed=$(( $(date +%s) - started ))
{
  echo "### Swift canary"
  echo
  echo "Targets: ${targets[*]}"
  echo "Elapsed: ${elapsed}s"
  echo "This is the fast PR gate for package-only CmuxNext Swift edits. The Release compile also runs on every PR that changes a CmuxNext Swift file, for Release-only optimizer failures a Debug build cannot see."
} >> "$GITHUB_STEP_SUMMARY"
