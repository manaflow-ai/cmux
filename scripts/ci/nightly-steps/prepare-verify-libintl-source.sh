#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Verify shipped libintl has its source". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# GNU libintl is LGPL-2.1-or-later. GhosttyKit and the ghostty CLI helper
# are built with -Di18n=false, so no shipped Mach-O may define a libintl
# symbol unless the channel release carries gettext-0.24.tar.gz and
# COPYING.LIB (the prune step keeps those names, they carry no build number).
set -euo pipefail
args=(build-universal/Build/Products/Release/cmux.app)
if [ -n "${CHANNEL_RELEASE_TAG:-}" ]; then
  args+=(--release-repo "$GITHUB_REPOSITORY" --release-tag "$CHANNEL_RELEASE_TAG")
fi
python3 scripts/verify_app_libintl.py "${args[@]}"
