#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Restore prepared app". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input. An unsigned resume
# checks out an older build commit, so the step runs this script from .nightly-signing-control when that tree lacks it.
set -euo pipefail
products="build-universal/Build/Products/Release"
mkdir -p "$products"
tar -C "$products" -xzf prepared-app/cmux-prepared-app.tar.gz
