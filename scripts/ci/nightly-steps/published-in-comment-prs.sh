#!/usr/bin/env bash
# nightly.yml published-in: "Comment the build on its PRs". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
# published-in-fetch-span.sh waits for the feed to offer this build and fetches its span; each PR's one status
# comment then gets "Shipped in NIGHTLY <build> at <UTC time>", edited in place on a rerun.
set -euo pipefail
# The nightly mini's address gets 403 from github.com unauthenticated, and checkout keeps no credentials
# (persist-credentials: false): this script's git fetches send the job token.
if [ -n "${GH_TOKEN:-}" ]; then
  header="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  echo "::add-mask::$header"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $header"
fi
out="$(mktemp)"
GITHUB_OUTPUT="$out" bash scripts/ci/nightly-steps/published-in-fetch-span.sh
value() { sed -n "s/^$1=//p" "$out" | tail -1; }
if [ "$(value moved)" != true ]; then exit 0; fi
python3 scripts/ci/published_in_comments.py --repo "$GITHUB_REPOSITORY" \
  --since "$(value since)" --head "$HEAD_SHA" \
  --name "NIGHTLY ${NIGHTLY_BUILD:-$NIGHTLY_VERSION}" --at "$(value at)" \
  --url "https://github.com/$GITHUB_REPOSITORY/releases/tag/nightly-next"
