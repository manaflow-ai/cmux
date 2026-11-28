#!/usr/bin/env bash
# web-bundle-matrix.yml, report job: the commit status `cmux-next/web-bundle-matrix` on the commit the matrix ran at.
# request-nightly-next.sh reads it (web_matrix_green): `failure` keeps the commit out of nightly-next.
# Env: GH_TOKEN (statuses: write), SHA, RESULT (success|failure), JOB FILE LINE, RUN_URL, GITHUB_REPOSITORY.
set -euo pipefail
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad sha '$SHA'"; exit 1; }
case "$RESULT" in
  success) state=success; desc="every web bundle builds on the merged tree" ;;
  failure) state=failure; desc="red in ${JOB:-?}: ${FILE:-?}:${LINE:-?}" ;;
  *) echo "no status for result '$RESULT'"; exit 0 ;;
esac
gh api -X POST "repos/$GITHUB_REPOSITORY/statuses/$SHA" -f state="$state" -f context="cmux-next/web-bundle-matrix" \
  -f description="${desc:0:140}" -f target_url="$RUN_URL" --silent
echo "cmux-next/web-bundle-matrix $state on ${SHA:0:12}" >> "$GITHUB_STEP_SUMMARY"
