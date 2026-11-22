#!/usr/bin/env bash
# nightly.yml publish-nightly: "Move channel release tag to built commit". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The channel's release tag is the fast completion marker used by the
# decide job. Move it to the fixed candidate selected at dispatch only
# after every publication step succeeds. A newer commit becomes the next
# run's candidate. The tag is deliberately the only operation using the
# elevated app token on classic channels (nightly-next also needs it for
# release metadata, see above); assets and feeds use the Actions token and
# remain the publication record if this marker is stale.
set -euo pipefail
# Every rc/** branch shares the rc tag and those branches diverge,
# so only the nightly tag requires a fast-forward. nightly-next may
# move from a baseline build (see promote-nightly-next on main). The helper retries
# only transient API/network failures and reads the ref back before
# declaring the marker updated. Permission failures are terminal.
python3 "$PUBLISH_TOOLING/ci/update-release-tag.py" \
  --repo "$GITHUB_REPOSITORY" \
  --tag "$CHANNEL_RELEASE_TAG" \
  --sha "${SOURCE_BUILD_SHA}" \
  ${ALLOW_NON_DESCENDANT_FLAG:+"$ALLOW_NON_DESCENDANT_FLAG"}
