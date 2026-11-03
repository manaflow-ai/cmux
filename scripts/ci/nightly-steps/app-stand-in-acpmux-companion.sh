#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Stand in for the acpmux companion while the tree publishes". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Bundle acpmux only aliases bin/acpmux to bin/cmux; its input file is never copied.
f="$RUNNER_TEMP/acpmux-input/acpmux"; mkdir -p "${f%/*}"; rm -f "$f.ref"; echo alias > "$f"
echo "CMUX_NEXT_ACPMUX_BIN=$f" >> "$GITHUB_ENV"
