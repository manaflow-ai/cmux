#!/usr/bin/env bash
# nightly.yml nightly-next-one, nightly-next track: the new build's Sparkle deltas from its nearest earlier builds
# (hq#13299), in two modes.
#
#   (no argument)  "Generate Sparkle appcasts (nightly)", BEFORE the feed is written. With
#                  NIGHTLY_NEXT_DELTAS_AFTER_FEED=true (nightly-next-one) it writes the item full-only and ends;
#                  without it (the split jobs) it builds the deltas here, as before.
#   after-feed     "Build the nightly-next deltas after the feed" (nightly-next-one), AFTER the feed is live: the
#                  deltas and an item that carries them go to nightly-deltas/, which
#                  republish-deltas-upload-next-appcasts.sh uploads and merges into the live item, only while
#                  this build is still the feed's newest (write-feed --same-build is the compare-and-swap).
#
# Why after: measured in run 44904268153 (job 136847063748, 2026-11-21), the step ran 12:51:31-12:55:56 and the
# feed was written at 12:59:50Z: 56 s downloading three earlier DMGs from R2 plus 203 s of BinaryDelta = 4.3 min
# on the critical path from landing to feed, for bytes that only matter to a Mac that is one build behind.
# hq#13299 stays satisfied: the deltas still follow the feed in the same job, about 4 min later, not 60-100 min
# later in a dispatched tail that a newer build (every ~30 min) had already replaced. The tail still adds only
# the ~1 and ~3 day bases (NIGHTLY_DELTAS_NEAREST_SHIPPED). Every failure in after-feed mode only warns: a delta is
# never worth failing a published build, and a Mac without one downloads the full DMG.
#
# Before hq#13299, nightly-next published every build full-only (243 MB) and the tail added deltas 60-100
# min later, once no newer build had replaced it; builds land about every 30 min, so the feed never served
# one. A delta from the previous build is 13.6 MB (run 44152453711). The steps:
#   1. scripts/ci/nightly_next_previous_dmgs.py takes the NEAREST_BASES newest earlier DMGs, from the copies this
#      Mac kept ($HOME/.cmux-nightly-next-dmg-cache, the newest 4 final DMGs, each used only when its size is
#      the Content-Length R2 serves) and otherwise from R2 (the builds the live feed names; no token, no API);
#   2. builds whose DMG embeds another Sparkle key are dropped (a delta from one can never install);
#   3. sparkle_generate_appcast.sh builds the deltas (BinaryDelta, SPARKLE_DELTA_JOBS at a time) and signs
#      the item and each delta with the key it already holds;
#   4. only the new build's item is kept: the feed write merges the live items as before.
# Any failure in the delta part publishes the build full-only, as before, with a warning.
#
# env (the step's): TRACK, NIGHTLY_DMG_IMMUTABLE, NIGHTLY_APPCAST, CHANNEL_RELEASE_TAG, CHANNEL_DMG_PREFIX,
# NIGHTLY_VARIANT, NIGHTLY_BUILD, NIGHTLY_NEXT_FEED_BASE, NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY,
# SPARKLE_MINIMUM_SYSTEM_VERSION, SPARKLE_CHANNEL, and the key selector's inputs (TRACK, CHANNEL,
# NEXT_SPARKLE_PRIVATE_KEY, ...): the signing key comes from scripts/ci/nightly-sparkle-key.sh here, as in
# every nightly signing step (tests/test_nightly_sparkle_key.sh), never from a SPARKLE_PRIVATE_KEY handed in.
set -euo pipefail
mode="${1:-publication}"
delta_dir=.
SPARKLE_PRIVATE_KEY="$(./scripts/ci/nightly-sparkle-key.sh)"
export SPARKLE_PRIVATE_KEY
: "${NIGHTLY_DMG_IMMUTABLE:?}" "${NIGHTLY_APPCAST:?}" "${CHANNEL_RELEASE_TAG:?}" "${CHANNEL_DMG_PREFIX:?}"
: "${NIGHTLY_VARIANT:?}" "${NIGHTLY_BUILD:?}" "${NIGHTLY_NEXT_FEED_BASE:?}"
NEAREST_BASES="${NIGHTLY_NEXT_NEAREST_DELTA_BASES:-3}"
export SPARKLE_DELTA_JOBS="${SPARKLE_DELTA_JOBS:-3}"
export SPARKLE_DELTA_NAME_PREFIX="${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-"
here="$(cd "$(dirname "$0")/.." && pwd)"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
previous="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nightly-next-nearest.XXXXXX")"
trap 'rm -rf "$previous"' EXIT
started=$SECONDS
feed_name="$NIGHTLY_APPCAST"
cache_dir="${NIGHTLY_NEXT_DMG_CACHE:-${HOME:-/nonexistent}/.cmux-nightly-next-dmg-cache}"
dmg_cache_keep="${NIGHTLY_NEXT_DMG_CACHE_KEEP:-4}"

full_only() {
  rm -f "${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}"-*.delta
  ./scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" "$CHANNEL_RELEASE_TAG" "$NIGHTLY_APPCAST"
  if grep -q 'sparkle:deltas' "$NIGHTLY_APPCAST"; then
    echo "ERROR: a full-only appcast must contain full archives only" >&2
    exit 1
  fi
}

if [ "$mode" = publication ] && [ "${NIGHTLY_NEXT_DELTAS_AFTER_FEED:-}" = true ]; then
  echo "Publishing $NIGHTLY_BUILD full-only; its deltas follow the feed (after-feed mode)"
  full_only
  echo "nightly-next deltas: after the feed; item written full-only in ${SECONDS}s" >> "$summary"
  exit 0
fi
case "$mode" in publication|after-feed) ;; *) echo "usage: appcast-with-nearest-deltas.sh [after-feed]" >&2; exit 2 ;; esac

# After the feed: nothing here may fail the build (the workflow steps are continue-on-error too).
if [ "$mode" = after-feed ]; then
  # Keep this build's final DMG for the builds after it: their deltas start from it.
  python3 "$here/nightly_next_previous_dmgs.py" --save "$NIGHTLY_DMG_IMMUTABLE" --cache-dir "$cache_dir" \
    --prefix "$CHANNEL_DMG_PREFIX" --variant "$NIGHTLY_VARIANT" --keep "$dmg_cache_keep" || true
  if ! python3 "$here/nightly_next_delta_check.py" newest --feed-url "${NIGHTLY_NEXT_FEED_BASE%/}/${feed_name}" \
      --build "$NIGHTLY_BUILD"; then
    echo "::notice::a newer build is on the feed (or it is unreadable); build $NIGHTLY_BUILD gets no nearest deltas"
    echo "nightly-next deltas: skipped, build $NIGHTLY_BUILD is no longer the feed's newest" >> "$summary"
    exit 0
  fi
  rm -rf nightly-deltas
  mkdir -p nightly-deltas
  NIGHTLY_APPCAST="nightly-deltas/$NIGHTLY_APPCAST"
  delta_dir=nightly-deltas
fi

deltas_ok=true
python3 "$here/nightly_next_previous_dmgs.py" --feed-url "${NIGHTLY_NEXT_FEED_BASE%/}/${feed_name}" \
  --base "$NIGHTLY_NEXT_FEED_BASE" --prefix "$CHANNEL_DMG_PREFIX" --variant "$NIGHTLY_VARIANT" \
  --build "$NIGHTLY_BUILD" --count "$NEAREST_BASES" --cache-dir "$cache_dir" --out "$previous" || deltas_ok=false
fetched=$((SECONDS - started))
if [ "$deltas_ok" = true ] && [ -n "${NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY:-}" ]; then
  bash "$here/drop-previous-nightlies-with-other-sparkle-key.sh" "$previous" "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" || deltas_ok=false
fi
bases="$(find "$previous" -maxdepth 1 -name '*.dmg' | wc -l | tr -d ' ')"
if [ "$deltas_ok" != true ] || [ "$bases" = 0 ]; then
  echo "No earlier build to diff from; $NIGHTLY_BUILD stays full-only"
  [ "$mode" = after-feed ] || full_only
  echo "nightly-next deltas: none (no earlier build on R2); signer time ${SECONDS}s" >> "$summary"
  exit 0
fi
if ! SPARKLE_PREVIOUS_ARCHIVES_DIR="$previous" SPARKLE_MAXIMUM_DELTAS="$bases" \
    ./scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" "$CHANNEL_RELEASE_TAG" "$NIGHTLY_APPCAST"; then
  echo "::warning::building the deltas failed; $NIGHTLY_BUILD stays full-only"
  [ "$mode" = after-feed ] || full_only
  echo "nightly-next deltas: FAILED, published full-only; signer time ${SECONDS}s" >> "$summary"
  exit 0
fi
python3 "$here/nightly_next_delta_check.py" keep-item "$NIGHTLY_APPCAST" --build "$NIGHTLY_BUILD"
built=0
for delta in "$delta_dir/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}"-*.delta; do
  [ -f "$delta" ] || continue
  built=$((built + 1))
  printf 'delta %s: %s bytes\n' "$delta" "$(wc -c < "$delta" | tr -d ' ')"
done
ls -l "$NIGHTLY_DMG_IMMUTABLE" "$NIGHTLY_DMG_RELEASE" "$NIGHTLY_APPCAST"
# The cost on the signer, for hq#13299: download of the bases, then BinaryDelta and signing.
{
  echo "### nightly-next deltas ($mode)"
  echo "$built delta(s) from $bases earlier build(s) on the signer in $SECONDS s (bases fetched in ${fetched} s)"
  for delta in "$delta_dir/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}"-*.delta; do
    [ -f "$delta" ] || continue
    echo "- $delta: $(( $(wc -c < "$delta") / 1000000 )) MB"
  done
} | tee -a "$summary"
