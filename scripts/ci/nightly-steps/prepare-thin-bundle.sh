#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Thin bundle to the variant architecture". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
./scripts/cmux-next/drop-cef-without-arch.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
# The Computer Use helper's Cua Driver SDK is arm64 only too (bundle-cmux-remote.sh). An older build
# tree (an unsigned resume) has neither the script nor the dylib.
if [[ -x scripts/cmux-next/drop-cua-sdk-without-arch.sh ]]; then
  ./scripts/cmux-next/drop-cua-sdk-without-arch.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
fi
./scripts/thin-app-bundle.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
