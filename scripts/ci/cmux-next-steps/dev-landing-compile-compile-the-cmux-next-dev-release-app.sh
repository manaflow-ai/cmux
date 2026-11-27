#!/usr/bin/env bash
# cmux-next.yml dev-landing-compile: "Compile the cmux NEXT DEV Release app".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
archive="$RUNNER_TEMP/cmux-next-dev-daily-unsigned-${GITHUB_SHA}.app.zip"
if [[ -n "$REUSED_ARCHIVE" && -f "$REUSED_ARCHIVE" ]]; then
  mv -f "$REUSED_ARCHIVE" "$archive"
else
  scripts/cmux-next/compile-dev-release.sh "$archive"
fi
echo "archive=$archive" >> "$GITHUB_OUTPUT"
