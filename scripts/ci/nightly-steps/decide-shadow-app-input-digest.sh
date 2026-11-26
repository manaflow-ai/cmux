#!/usr/bin/env bash
# nightly.yml decide: "Shadow the app-input digest". Reads only: computes scripts/ci/app_input_digest.py for the
# candidate and for the last published nightly-next commit, and reports app_input_digest and would_reuse (true when
# the two match, so a build would add nothing). Changes no decision, adds no GitHub API call (git protocol only),
# and never fails the job: every error ends in would_reuse=unknown and exit 0.
# Clean-sheet CI RFD: hq#26225. The nightly-speed recorder (scripts/ci/nightly_speed.py) reads run outputs and
# step summaries after the fact, so the values go to both GITHUB_OUTPUT and GITHUB_STEP_SUMMARY.
set -uo pipefail
head_sha="${HEAD_SHA:-}"
published="${PUBLISHED_SHA:-}"
digest=unknown
reuse=unknown
published_digest=
if [[ -n "$head_sha" ]]; then
  if [[ -n "$published" ]]; then
    # --depth only in a checkout that is already shallow, so a full clone stays full.
    depth=()
    [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1)
    bash scripts/ci/timeout.sh 60 git fetch --no-tags --quiet ${depth[@]+"${depth[@]}"} --filter=blob:none origin "$published" >/dev/null 2>&1 || true
  fi
  # A blobless fetch lets git read missing blobs on demand; the timeout bounds that.
  digest="$(bash scripts/ci/timeout.sh 120 python3 scripts/ci/app_input_digest.py --ref "$head_sha" 2>/dev/null)" || digest=unknown
  if [[ -n "$published" ]]; then
    published_digest="$(bash scripts/ci/timeout.sh 120 python3 scripts/ci/app_input_digest.py --ref "$published" 2>/dev/null)" || published_digest=
  fi
  if [[ "$digest" != unknown && -n "$published_digest" ]]; then
    if [[ "$digest" == "$published_digest" ]]; then reuse=true; else reuse=false; fi
  fi
fi
{
  echo "app_input_digest=$digest"
  echo "would_reuse=$reuse"
} >> "${GITHUB_OUTPUT:-/dev/null}"
{
  echo "### App input digest (shadow, no behaviour change)"
  echo "- candidate \`${head_sha:0:12}\`: \`$digest\`"
  echo "- last published \`${published:0:12}\`: \`${published_digest:-unknown}\`"
  echo "- would_reuse: \`$reuse\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "app_input_digest=$digest would_reuse=$reuse"
exit 0
