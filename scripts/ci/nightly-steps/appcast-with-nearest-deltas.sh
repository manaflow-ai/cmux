#!/usr/bin/env bash
# nightly.yml "Generate Sparkle appcasts (nightly)", nightly-next track: the new build's appcast with the
# Sparkle deltas from its nearest earlier builds, before the feed is written (hq#13299).
#
# Before, nightly-next published every build full-only (243 MB) and a dispatched tail added deltas 60-100
# min later, once no newer build had replaced it; builds land about every 30 min, so the feed never served
# one. A delta from the previous build is 13.6 MB (run 44152453711). Here the build ships with them:
#   1. scripts/ci/nightly_next_previous_dmgs.py downloads the NEAREST_BASES newest earlier DMGs from R2
#      (the builds the live feed names; no token, no API);
#   2. builds whose DMG embeds another Sparkle key are dropped (a delta from one can never install);
#   3. sparkle_generate_appcast.sh builds the deltas (BinaryDelta, SPARKLE_DELTA_JOBS at a time) and signs
#      the item and each delta with the key it already holds;
#   4. only the new build's item is kept: the feed write merges the live items as before.
# Any failure in the delta part publishes the build full-only, as before, with a warning: a delta is
# never worth a held publication. Sparkle on a Mac whose build has no delta downloads the full DMG.
#
# env (the step's): TRACK, NIGHTLY_DMG_IMMUTABLE, NIGHTLY_APPCAST, CHANNEL_RELEASE_TAG, CHANNEL_DMG_PREFIX,
# NIGHTLY_VARIANT, NIGHTLY_BUILD, NIGHTLY_NEXT_FEED_BASE, NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY,
# SPARKLE_PRIVATE_KEY, SPARKLE_MINIMUM_SYSTEM_VERSION, SPARKLE_CHANNEL
set -euo pipefail
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

full_only() {
  rm -f "${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}"-*.delta
  ./scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" "$CHANNEL_RELEASE_TAG" "$NIGHTLY_APPCAST"
  if grep -q 'sparkle:deltas' "$NIGHTLY_APPCAST"; then
    echo "ERROR: a full-only appcast must contain full archives only" >&2
    exit 1
  fi
}

deltas_ok=true
python3 "$here/nightly_next_previous_dmgs.py" --feed-url "${NIGHTLY_NEXT_FEED_BASE%/}/${NIGHTLY_APPCAST}" \
  --base "$NIGHTLY_NEXT_FEED_BASE" --prefix "$CHANNEL_DMG_PREFIX" --variant "$NIGHTLY_VARIANT" \
  --build "$NIGHTLY_BUILD" --count "$NEAREST_BASES" --out "$previous" || deltas_ok=false
fetched=$((SECONDS - started))
if [ "$deltas_ok" = true ] && [ -n "${NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY:-}" ]; then
  bash "$here/drop-previous-nightlies-with-other-sparkle-key.sh" "$previous" "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" || deltas_ok=false
fi
bases="$(find "$previous" -maxdepth 1 -name '*.dmg' | wc -l | tr -d ' ')"
if [ "$deltas_ok" != true ] || [ "$bases" = 0 ]; then
  echo "No earlier build to diff from; publishing $NIGHTLY_BUILD full-only"
  full_only
  echo "nightly-next deltas: none (no earlier build on R2); signer time ${SECONDS}s" >> "$summary"
  exit 0
fi
if ! SPARKLE_PREVIOUS_ARCHIVES_DIR="$previous" SPARKLE_MAXIMUM_DELTAS="$bases" \
    ./scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" "$CHANNEL_RELEASE_TAG" "$NIGHTLY_APPCAST"; then
  echo "::warning::building the deltas failed; publishing $NIGHTLY_BUILD full-only"
  full_only
  echo "nightly-next deltas: FAILED, published full-only; signer time ${SECONDS}s" >> "$summary"
  exit 0
fi
python3 "$here/nightly_next_delta_check.py" keep-item "$NIGHTLY_APPCAST" --build "$NIGHTLY_BUILD"
built=0
for delta in "${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}"-*.delta; do
  [ -f "$delta" ] || continue
  built=$((built + 1))
  printf 'delta %s: %s bytes\n' "$delta" "$(wc -c < "$delta" | tr -d ' ')"
done
ls -l "$NIGHTLY_DMG_IMMUTABLE" "$NIGHTLY_DMG_RELEASE" "$NIGHTLY_APPCAST"
# The cost on the signer, for hq#13299: download of the bases, then BinaryDelta and signing.
{
  echo "### nightly-next deltas at publication"
  echo "$built delta(s) from $bases earlier build(s) on the signer in $SECONDS s (bases fetched in ${fetched} s)"
  for delta in "${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}"-*.delta; do
    [ -f "$delta" ] || continue
    echo "- $delta: $(( $(wc -c < "$delta") / 1000000 )) MB"
  done
} | tee -a "$summary"
