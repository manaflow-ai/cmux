#!/usr/bin/env bash
# cmux-next.yml release-compile: "Fetch the Chromium engine".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
if cef_dir="$(env -u GH_TOKEN -u GITHUB_TOKEN scripts/cmux-next/ensure-cef.sh --optional)" && [[ -n "$cef_dir" ]]; then
  echo "Chromium engine at $cef_dir"
  echo "dir=$cef_dir" >> "$GITHUB_OUTPUT"
else
  echo "::notice::Chromium engine artifact not readable on this runner; skipping the CEF shim compile"
fi
