#!/usr/bin/env bash
# cmux-next.yml release-compile: "Warn on missing Release bundle notices".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
# Why: note-484
derived_data="${CMUX_NEXT_RELEASE_DERIVED_DATA:-$(scripts/cmux-next/release-derived-data-path.sh release-compile Release)}"
app="$(find "$derived_data/Build/Products/Release" -maxdepth 2 -type d -name '*.app' -print -quit 2>/dev/null || true)"
if [[ -z "$app" ]]; then
  echo "::warning title=Release bundle notices::no Release .app product was found for the advisory notice scan"
  exit 0
fi
if ! scripts/verify-app-bundle-licenses.sh "$app"; then
  echo "::warning title=Release bundle notices::the advisory scan found a missing or unmapped bundled binary; the signed nightly check remains required"
fi
