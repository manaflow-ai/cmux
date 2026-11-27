#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Compile the cmux scheme".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
if [[ "$CMUX_NEXT_RUNNER" == glaeda-* ]]; then
  derived_data="$HOME/Library/Caches/cmux-next-ci/cmux-scheme/${RUNNER_NAME:-runner}"
  # Why: note-487
  if [[ -d "$derived_data" ]] && (( $(du -sg "$derived_data" | cut -f1) > 12 )); then
    echo "kept DerivedData over 12 GiB; building cold"
    rm -rf -- "$derived_data"
  fi
else
  derived_data="$RUNNER_TEMP/cmux-scheme-compile"
fi
scripts/cmux-next/check-cmux-scheme-compile.sh "$derived_data"
echo "CMUX_NEXT_DERIVED_DATA=$derived_data" >> "$GITHUB_ENV"
# Why: note-500
scripts/cmux-next/check-app-personalities.sh "$(find "$derived_data/Build/Products/Debug" -maxdepth 1 -name 'cmux DEV*.app' -print -quit)"
