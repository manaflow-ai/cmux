#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Choose the build commit". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
build_sha="${SOURCE_COMMIT:-$TIP_SHA}"
[[ "$build_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no build commit" >&2; exit 1; }
# One machine-readable log line naming the commit this run builds and checks (its head_sha can be another: a resume
# builds its original run's commit). Readers of job logs (cmuxterm-hq base-red-watch) attribute the run's verdicts to it.
echo "built_sha=$build_sha tip_sha=$TIP_SHA"
{
  echo "build_sha=$build_sha"
  echo "build_short_sha=${build_sha:0:7}"
  echo "behind=${BEHIND:-0}"
  echo "behind_hours=${BEHIND_HOURS:-0}"
} >> "$GITHUB_OUTPUT"
already_published=false
if [[ "$SHOULD_PUBLISH" == true && "$FORCE_BUILD" != true && "$build_sha" == "$PUBLISHED_SHA" ]]; then
  already_published=true
  echo "::notice title=Nightly already published::the resolved build commit $build_sha is already published; nothing to build (force=true rebuilds it)"
fi
echo "already_published=$already_published" >> "$GITHUB_OUTPUT"
{
  echo "### Nightly build commit"
  echo "- build commit (app and cmux-tui daemon): \`$build_sha\`"
  echo "- tip: \`$TIP_SHA\` (${BEHIND:-0} commits and ${BEHIND_HOURS:-0} h behind)"
  echo "- already published: $already_published"
} >> "$GITHUB_STEP_SUMMARY"
