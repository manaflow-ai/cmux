#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github-names: "Move the nightly-next tag to the published build". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
"$RUNNER_TEMP/still-newest" || exit 0
python3 "$PUBLISH_TOOLING/ci/update-release-tag.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --sha "$BUILD_SHA" --allow-non-descendant
