#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Package prepared app for signing". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
mkdir -p prepared-app-handoff
tar -C build-universal/Build/Products/Release -czf prepared-app-handoff/cmux-prepared-app.tar.gz cmux.app
