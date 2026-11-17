#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Thin bundle to the variant architecture". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
./scripts/cmux-next/drop-cef-without-arch.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
# cmux Remote (embed-cmux-remote-dev.sh) is arm64 only and thinning leaves its signed bytes alone, so
# an x86_64 variant drops it, as it drops the arm64-only Chromium engine.
if [[ "$NIGHTLY_VARIANT" == x86_64 ]]; then
  for remote in build-universal/Build/Products/Release/cmux.app/Contents/Library/"cmux Remote"*.app; do
    if [[ -d "$remote" ]]; then
      echo "::warning title=No cmux Remote for x86_64::$(basename "$remote") is arm64 only; the x86_64 app ships without it"
      rm -rf "$remote"
    fi
  done
fi
./scripts/thin-app-bundle.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
