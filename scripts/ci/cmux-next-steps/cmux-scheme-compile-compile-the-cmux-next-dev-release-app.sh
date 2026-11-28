#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Compile the cmux NEXT DEV Release app".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
if [[ -n "$REUSED_ARCHIVE" && -f "$REUSED_ARCHIVE" ]]; then
  # Why: note-501
  archive="$RUNNER_TEMP/cmux-next-dev-daily-unsigned-${DEV_DAILY_SHA}.app.zip"
  mv -f "$REUSED_ARCHIVE" "$archive"
  echo "archive=$archive" >> "$GITHUB_OUTPUT"
  exit 0
fi
# Why: note-545
[[ "$CMUX_NEXT_RUNNER" == glaeda-* || "${CMUX_NEXT_DEV_VM_CACHE:-}" == 1 ]] || export CMUX_NEXT_COMPILATION_CACHE=0
# Why: note-459
archive="$RUNNER_TEMP/cmux-next-dev-daily-unsigned-${DEV_DAILY_SHA}.app.zip"
scripts/cmux-next/compile-dev-release.sh "$archive"
echo "archive=$archive" >> "$GITHUB_OUTPUT"
