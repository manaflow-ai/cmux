#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Restore unsigned nightly products". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
products="build-universal/Build/Products/Release"
mkdir -p "$products"
# The Mac's tar records extended attributes GNU tar does not restore.
# On an owned Mac (the outage fallback) the Mac's own tar restores them,
# as this job did before it moved to Linux (#25885).
if [ "$RUNNER_OS" = Linux ]; then
  tar --warning=no-unknown-keyword -C "$products" -xzf nightly-inputs/app/cmux-nightly-unsigned.tar.gz
else
  tar -C "$products" -xzf nightly-inputs/app/cmux-nightly-unsigned.tar.gz
fi
