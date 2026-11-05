#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Thin bundle to the variant architecture". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
./scripts/cmux-next/drop-cef-without-arch.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
./scripts/thin-app-bundle.sh build-universal/Build/Products/Release/cmux.app "$NIGHTLY_VARIANT"
