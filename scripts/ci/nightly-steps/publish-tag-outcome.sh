#!/usr/bin/env bash
# nightly.yml publish-nightly: "Record nightly publication marker outcome". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
if [ "$TAG_MOVE_OUTCOME" = "success" ] && [ "$CHANNEL_RELEASE_TAG" = nightly-next ]; then
  if [ "${NEXT_FEED_CURRENT:-false}" != true ]; then
    echo "tag_status=unpublished" >> "$GITHUB_OUTPUT"
    echo "The nightly-next feed did not accept this build; no release metadata or tag will move."
    exit 0
  fi
  echo "tag_status=updated" >> "$GITHUB_OUTPUT"
  {
    echo "### Feed current"
    echo ""
    echo "\`$CHANNEL_FEED_BASE\` serves \`$HEAD_SHA\` from R2; publish-nightly-next-github copies it to the release and moves the tag."
  } >> "$GITHUB_STEP_SUMMARY"
elif [ "$TAG_MOVE_OUTCOME" = "success" ]; then
  echo "tag_status=updated" >> "$GITHUB_OUTPUT"
  {
    echo "### Channel release tag updated"
    echo ""
    echo "\`$CHANNEL_RELEASE_TAG\` now points to \`$HEAD_SHA\`."
  } >> "$GITHUB_STEP_SUMMARY"
elif [ "$TAG_MOVE_OUTCOME" != "failure" ]; then
  # The tag move runs only after every publication step succeeded, so
  # a skipped or cancelled move means the publication itself stopped
  # (run 40076543798 said "are live" when no asset had uploaded).
  # Name what each part did instead of claiming any of it is live.
  appcasts="$APPCASTS_OUTCOME"
  if [ -z "$appcasts" ] || [ "$appcasts" = "skipped" ]; then
    appcasts="$NEXT_APPCASTS_OUTCOME"
  fi
  case "$appcasts" in
    success) appcast_state="updated" ;;
    skipped|"") appcast_state="not uploaded, still serving the previous build" ;;
    *) appcast_state="$appcasts, may be partly updated" ;;
  esac
  parts="release assets: ${ASSETS_OUTCOME:-not run}; release metadata: ${METADATA_OUTCOME:-not run}; appcasts: $appcast_state; $CHANNEL_RELEASE_TAG tag: not moved"
  if [ "$ASSETS_OUTCOME" != "success" ] && [ "${METADATA_OUTCOME:-skipped}" = "skipped" ] && [ "$appcast_state" = "not uploaded, still serving the previous build" ]; then
    headline="Nothing is live for $HEAD_SHA"
  else
    headline="Publication of $HEAD_SHA did not complete"
  fi
  echo "tag_status=unpublished" >> "$GITHUB_OUTPUT"
  echo "::warning::$headline ($parts). See the first failed step above."
  {
    echo "### Not published"
    echo ""
    echo "$headline ($parts)."
  } >> "$GITHUB_STEP_SUMMARY"
else
  echo "tag_status=stale" >> "$GITHUB_OUTPUT"
  echo "::warning::Published assets, release metadata, and appcasts are live; the $CHANNEL_RELEASE_TAG tag marker is stale because its final update failed."
  {
    echo "### Published, tag marker stale"
    echo ""
    echo "Assets, release metadata, and appcasts for \`$HEAD_SHA\` are published, but \`$CHANNEL_RELEASE_TAG\` was not advanced. The next eligible publication will retry the marker without republishing this commit."
  } >> "$GITHUB_STEP_SUMMARY"
fi


      # Never fails the job (later jobs need it); report-nightly-failure reads feed_check.
