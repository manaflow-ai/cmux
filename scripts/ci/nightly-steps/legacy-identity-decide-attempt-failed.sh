#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Decide whether the attempt failed". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# Search, not a one-page listing: the issue may be past the first 100 open
# issues and pull requests (scripts/ci/nightly-next-legacy-failure-issue.sh).
# The attempt failed when signing failed, or when a build Apple is done
# with was not published (the static verify, the digest check, the appcast
# or the upload failed). A submission still in Apple's queue never fails.
set -euo pipefail
job_ok=false
if [ "$JOB_STATUS" = success ]; then job_ok=true; fi
decision="$(python3 scripts/ci/nightly-next-legacy-attempt.py --sign-result "$SIGN_RESULT" --sign-skip "$SIGN_SKIP" \
  --signed-ok "$SIGN_OK" --pending "$SIGN_PENDING" --published "$PUBLISHED" --job-ok "$job_ok")"
echo "$decision" >> "$GITHUB_OUTPUT"
echo "attempt: sign $SIGN_RESULT skip=$SIGN_SKIP ok=$SIGN_OK pending=$SIGN_PENDING; tested=${TESTED_SHA256:-none}; published=$PUBLISHED -> $decision"
