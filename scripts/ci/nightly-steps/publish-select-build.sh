#!/usr/bin/env bash
# nightly.yml publish-nightly: "Select the build to publish". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# Why: docs/ci/nightly-workflow-notes/2026-11-26-publish-nightly-select-the-build-to-publish.md
set -euo pipefail
run_id=
cef=false source_archive=false
# Language packs (CMUX-570) are on unless CMUX_NEXT_LANGUAGE_PACKS is 0; a recovered build's
# packs stay in its own run (language_packs_run), a republished one's come from its receipt.
language_packs=true language_packs_run=
[ "${LANGUAGE_PACKS:-}" = 0 ] && language_packs=false
[ "${CEF_ON_DEMAND:-}" = 1 ] && cef=true
[ "${PUBLISH_SOURCE_ARCHIVE:-}" = 1 ] && source_archive=true
if [ "$OWN_RESULT" = success ] && [ "$OWN_PENDING" != true ] && [ "$OWN_VERIFIED" = success ] && [ "$OWN_DMG_VERIFIED" = success ] && [ "$OWN_TREE" = ok ]; then
  source=own build="$OWN_BUILD" build_sha="$OWN_BUILD_SHA" tip_sha="$OWN_TIP_SHA"
  behind="$OWN_BEHIND" behind_hours="$OWN_BEHIND_HOURS" pattern="cmux-nightly-variant-*"
  tested_pattern="cmux-nightly-tested-*"
elif [ "$RECOVERED" = true ] && [ "$RECOVERED_VERIFIED" = success ]; then
  source=recovered build="$RECOVERED_BUILD" build_sha="$RECOVERED_BUILD_SHA" tip_sha="$RECOVERED_TIP_SHA"
  behind="$RECOVERED_BEHIND" behind_hours="$RECOVERED_BEHIND_HOURS" pattern="cmux-nightly-recovered-variant-*"
  tested_pattern="cmux-nightly-recovered-tested-*" run_id="$RECOVERED_RUN_ID"
  language_packs_run="$RECOVERED_RUN_ID"
  echo "::notice title=Publishing an earlier nightly-next build::this run's build was not accepted in time; publishing build $build from run $RECOVERED_RUN_ID"
elif [ "${REPUBLISHED:-}" = success ]; then
  # Published as a recovered build: the lineage and webview gate read its run.
  source=recovered build="$REPUBLISHED_BUILD" build_sha="$REPUBLISHED_BUILD_SHA" tip_sha="$REPUBLISHED_TIP_SHA"
  behind="$REPUBLISHED_BEHIND" behind_hours="$REPUBLISHED_BEHIND_HOURS" pattern="cmux-nightly-republished-variant-*"
  tested_pattern="cmux-nightly-republished-tested-*" run_id="$REPUBLISHED_RUN_ID"
  [ "${REPUBLISHED_CEF:-}" = true ] && cef=true || cef=false
  [ "${REPUBLISHED_LANGUAGE_PACKS:-}" = true ] && language_packs=true || language_packs=false
  [ "${REPUBLISHED_SOURCE_ARCHIVE:-}" = true ] || source_archive=false
  echo "::notice title=Republishing a verified nightly-next build::build $build from run $REPUBLISHED_RUN_ID, with this run's publication tooling"
else
  echo "nothing accepted to publish" >&2
  exit 1
fi
[[ "$build" =~ ^[0-9]+$ && "$build_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build $build at $build_sha" >&2; exit 1; }
{
  echo "source=$source"
  echo "build=$build"
  echo "build_sha=$build_sha"
  echo "build_short_sha=${build_sha:0:7}"
  echo "tip_sha=$tip_sha"
  echo "behind=$behind"
  echo "behind_hours=$behind_hours"
  echo "variant_pattern=$pattern"
  echo "tested_pattern=$tested_pattern"
  echo "run_id=$run_id"
  echo "cef=$cef"
  echo "language_packs=$language_packs"
  echo "language_packs_run=$language_packs_run"
  echo "source_archive=$source_archive"
} >> "$GITHUB_OUTPUT"
echo "NIGHTLY_BUILD=$build" >> "$GITHUB_ENV"
