#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Package the trusted cmux-next dogfood artifact".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
app="$(find "$CMUX_NEXT_DERIVED_DATA/Build/Products/Debug" -maxdepth 1 -type d -name 'cmux DEV*.app' -print -quit)"
test -d "$app"
if [[ -n "$PR" ]]; then
  artifact_name="dogfood-app-${PR}-${HEAD_SHA}"
else
  artifact_name="cmux-next-base-app-${HEAD_SHA}"
fi
archive="$RUNNER_TEMP/${artifact_name}.app.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
echo "artifact_name=$artifact_name" >> "$GITHUB_OUTPUT"
echo "archive=$archive" >> "$GITHUB_OUTPUT"
