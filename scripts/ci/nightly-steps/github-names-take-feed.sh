#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github-names: "Take the published feed". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
for feed in $NIGHTLY_FEEDS; do cp "next-github/$feed" "nightly-out/$feed"; done
if [ -f next-github/nightly-prs.md ]; then cp next-github/nightly-prs.md "$RUNNER_TEMP/nightly-prs.md"; fi
