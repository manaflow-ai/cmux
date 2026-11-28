#!/usr/bin/env bash
# nightly.yml republish-nightly-deltas: "Upload revised nightly-next appcasts to R2". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# As in publish-nightly: the nightly-next track writes only its own
# bucket prefix with its scoped token, after the guard checks each feed.
set -euo pipefail
r2=.publish-tooling/scripts/ci/publish-nightly-next-r2.py
check=.publish-tooling/scripts/ci/nightly_next_delta_check.py
# The deltas beside the DMG on R2, all at once; then every enclosure R2 serves at
# its length points there (an older build from before R2 keeps its release URL).
files=()
for delta in nightly-deltas/*.delta; do files+=(--file "$delta"); done
# One failed upload no longer drops every delta: run 44152453711 (2026-11-17) built five, one R2 upload got
# "Connection reset by peer" four times, and set -e left the feed full-only. The rest still ship; prune below
# drops the one R2 does not serve (its URL stays the GitHub release's, where nightly-next uploads no delta).
if ! python3 "$r2" upload "${files[@]}"; then
  echo "::warning::Some deltas did not reach R2; the feed offers the ones that did"
fi
scratch="$(mktemp -d)"
live="$scratch/live.xml"
generated="$scratch/generated.xml"
trap 'rm -f "$live" "$generated"; rmdir "$scratch"' EXIT
for feed in nightly-deltas/appcast*.xml; do
  [ -f "$feed" ] || continue
  # The tail's deltas (the ~1 and ~3 day bases) join the live item, whose nearest deltas the publication
  # shipped (hq#13299): the live bytes stay, only enclosures for new bases are added.
  cp "$feed" "$generated"
  curl -fsSL --max-time 60 --retry 3 --retry-all-errors -A "cmux-delta-publisher/1" -H "Cache-Control: no-cache" \
    -o "$live" "${CHANNEL_FEED_BASE%/}/$(basename "$feed")"
  for attempt in 1 2 3 4 5; do
    # A newer publication may have pruned this build from the live ring. Check the
    # snapshot before merge, which requires this build's item to exist.
    if [ "${DELTAS_ONLY_WHILE_NEWEST:-}" = 1 ] && ! python3 "$check" newest --feed-file "$live" --build "$NIGHTLY_BUILD"; then
      echo "::notice::A newer build is live; its own publication owns its deltas, so $(basename "$feed") is left as is"
      break
    fi
    python3 "$check" merge "$live" "$generated" --build "$NIGHTLY_BUILD" --out "$feed"
    python3 "$r2" rewrite --feed "$feed" --if-public
    python3 "$check" prune "$feed" --base "$CHANNEL_FEED_BASE/"
    python3 .publish-tooling/scripts/ci/nightly-next-guard.py appcast "$feed"
    if python3 "$r2" write-feed --feed "$feed" --same-build --expected-feed "$live"; then
      break
    else
      status=$?
    fi
    # Exit 3 returns the origin bytes that won. Start again from the original
    # generated deltas so both writers' changes survive.
    if [ "$status" -ne 3 ] || [ "$attempt" -eq 5 ]; then exit "$status"; fi
  done
done
# The detector: deltas were built, so the live feed's item for this build must offer them, each served at its
# length. A newer build on the feed passes with a notice (its own tail owns its deltas).
python3 "$check" check --feed-url "$CHANNEL_FEED_BASE/appcast-arm64.xml" --build "$NIGHTLY_BUILD" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
