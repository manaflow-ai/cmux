#!/usr/bin/env bash
# cmux-next.yml checks: "No new SwiftUI (macOS UI is AppKit)".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
base=()
[[ "$EVENT_NAME" == pull_request ]] && base=(--base HEAD^1)
if [[ "$EVENT_NAME" == push && -n "$BEFORE" && "$BEFORE" != 0000000000000000000000000000000000000000 ]]; then
  git cat-file -e "$BEFORE^{commit}" 2>/dev/null \
    || git fetch --no-tags --quiet --depth=1 origin "$BEFORE" || true
  git cat-file -e "$BEFORE^{commit}" 2>/dev/null && base=(--base "$BEFORE")
fi
python3 -I scripts/cmux-next/check-no-swiftui.py ${base[@]+"${base[@]}"} "$GITHUB_WORKSPACE"
