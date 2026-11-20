#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github: "Prune old nightly release assets". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
python3 "$PUBLISH_TOOLING/prune_nightly_release_assets.py" \
  --repo manaflow-ai/cmux \
  --release-tag "$CHANNEL_RELEASE_TAG" \
  --name-prefix "${CHANNEL_DMG_PREFIX}-" \
  --keep-builds 100 \
  --max-assets 950 \
  --best-effort \
  --execute
