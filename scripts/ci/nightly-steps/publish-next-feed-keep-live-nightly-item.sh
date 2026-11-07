#!/usr/bin/env bash
# nightly.yml publish-nightly: "Keep the live feed's newest Nightly item beside the new build". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# cmux NEXT's critical path (Leo, 2026-10-26: "how are we even spending more than one
# minute on uploads?"): the DMG goes to the feed's own R2 base and the feed names it
# there, so the feed never waits on GitHub. The release upload spent 13-18 minutes in
# secondary rate-limit backoff (runs 40357982361, 40376320918). The GitHub release copy,
# its aliases, metadata and tag follow in publish-nightly-next-github, which never holds
# the feed. Same bytes, so the item's EdDSA signature is unchanged.
read -r -a feeds <<<"$NIGHTLY_FEEDS"
bash .publish-tooling/scripts/ci/nightly-steps/publish-next-feed-keep-nightly.sh "${feeds[@]/#/nightly-out/}"
