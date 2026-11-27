#!/usr/bin/env bash
# nightly.yml republish-nightly-deltas: "Republish deltas and revised appcasts". Moved out of the workflow to keep
# nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: sets every input.
set -euo pipefail
# The tag itself: `commits/<name>` resolves the nightly-next branch,
# which the promote job moves ahead during a build, and a skipped
# republish leaves the feed without its previous item (cx-urd.67).
# nightly-next: publish-nightly-next-github moves the tag later, off the feed's
# path; the live feed check below is the order check there.
if [ "${TRACK:-}" != nightly-next ]; then
  tag_object="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$CHANNEL_RELEASE_TAG" --jq '.object.type + " " + .object.sha')"
  read -r tag_type current_sha <<< "$tag_object"
  if [ "$tag_type" = tag ]; then
    current_sha="$(gh api "repos/$GITHUB_REPOSITORY/git/tags/$current_sha" --jq .object.sha)"
  fi
  # The publication moved the tag to the resolved build commit.
  if [ "$current_sha" != "$RESOLVE_BUILD_SHA" ]; then
    echo "Skipping stale delta result: $CHANNEL_RELEASE_TAG is at $current_sha"
    echo "publish=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi
if [ -n "${CHANNEL_FEED_BASE:-}" ]; then
  live_feed="$(mktemp)"
  curl -fsSL --retry 3 -A "cmux-delta-publisher/1" -o "$live_feed" "$CHANNEL_FEED_BASE/appcast-arm64.xml"
  live_build="$(python3 -c 'import sys,xml.etree.ElementTree as E; r=E.parse(sys.argv[1]).getroot(); print(next(c.text or "" for i in r.iter() if i.tag.rsplit("}", 1)[-1] == "item" for c in i if c.tag.rsplit("}", 1)[-1] == "version"))' "$live_feed")"
  # Above: a newer build published. Below: nightly-next-rollback.yml
  # pulled this one, and the revised appcast would put it back.
  if [[ "$live_build" =~ ^[0-9]+$ && "$NIGHTLY_BUILD" =~ ^[0-9]+$ ]] && (( live_build != NIGHTLY_BUILD )); then
    echo "Skipping stale delta result: NEXT feed serves build $live_build, not $NIGHTLY_BUILD"
    echo "publish=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi
deltas=()
for delta in nightly-deltas/*.delta; do
  [ -f "$delta" ] || continue
  deltas+=(--immutable "$delta")
done
if [ "${#deltas[@]}" -eq 0 ]; then
  echo "No Sparkle deltas were generated; full appcasts remain current"
  echo "publish=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
# The revised feed lists earlier builds again, all on the new build's
# ring: each goes back to Nightly when its canary verdict is a pass. It
# keeps the live feed's newest Nightly item as publish-nightly does.
if [ "$TRACK" = nightly-next ]; then
  bash .publish-tooling/scripts/ci/nightly-steps/publish-next-feed-keep-nightly.sh nightly-deltas/appcast*.xml
  for feed in nightly-deltas/appcast*.xml; do
    [ -f "$feed" ] || continue
    python3 .publish-tooling/scripts/ci/nightly_next_ring.py retag --feed "$feed" --out "$feed" \
      --mode "$DEV_RING" --verdicts-base "$NIGHTLY_NEXT_VERDICTS_BASE"
  done
fi
feeds=()
for feed in nightly-deltas/appcast*.xml; do
  [ -f "$feed" ] || continue
  feeds+=(--feed "$feed")
done
[ "${#feeds[@]}" -gt 0 ]
if [ "${TRACK:-}" = nightly-next ]; then
  # The deltas and the revised feed go to R2 in the next step, not to the release.
  echo "publish=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
# The workflow commit's publisher: its rate-limit backoff, serial uploads, shared wait.
publisher=.publish-tooling/scripts/ci/publish-release-assets.py
python3 "$publisher" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  ${deltas[@]+"${deltas[@]}"} --replace-feeds ${feeds[@]+"${feeds[@]}"}
echo "publish=true" >> "$GITHUB_OUTPUT"
