#!/usr/bin/env bash
# Build Sparkle deltas to this nightly build from the newest earlier builds of
# its track, and the revised appcast that offers them.
#
#   scripts/ci/generate-nightly-deltas.sh <new.dmg> <full-feed.xml> <out-dir>
#
# Environment: CHANNEL_RELEASE_TAG, CHANNEL_DMG_PREFIX, NIGHTLY_VARIANT,
# NIGHTLY_BUILD, GH_TOKEN, the key variables scripts/ci/nightly-sparkle-key.sh
# reads, and optionally SPARKLE_CHANNEL and GITHUB_REPOSITORY.
#
# A Mac downloads a delta only when its installed build is a delta base; any
# other Mac downloads the full DMG. Macs check hourly and nightly-next ships
# every 20-40 minutes, so a running Mac is usually 1-3 builds behind and a Mac
# that slept is a day or more behind. The bases are the three newest earlier
# builds plus the newest ones at least 24 and 72 hours old.
#
# <out-dir> receives the revised feed (named like <full-feed.xml>) and one
# "<prefix>-<variant>-<new>-<old>.delta" per base. With no earlier build to
# diff from, the full feed is copied unchanged.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  sed -n '2,5p' "$0" >&2
  exit 2
fi
DMG="$1"
FULL_FEED="$2"
OUT_DIR="$3"
: "${CHANNEL_RELEASE_TAG:?}" "${CHANNEL_DMG_PREFIX:?}" "${NIGHTLY_VARIANT:?}" "${NIGHTLY_BUILD:?}"
RECENT_BASES=3
OLDER_BASE_HOURS=(24 72)

scripts_dir="$(cd "$(dirname "$0")/.." && pwd)"
feed="$(basename "$FULL_FEED")"
test -s "$DMG"
mkdir -p "$OUT_DIR"
previous="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nightly-delta-previous.XXXXXX")"
previous_dates="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nightly-delta-dates.XXXXXX")"
trap 'rm -rf "$previous" "$previous_dates"' EXIT

python3 "$scripts_dir/ci/fetch-previous-nightly-dmgs.py" \
  --repo "${GITHUB_REPOSITORY:-manaflow-ai/cmux}" \
  --release-tag "$CHANNEL_RELEASE_TAG" \
  --name-prefix "${CHANNEL_DMG_PREFIX}-" \
  --variant "$NIGHTLY_VARIANT" \
  --exclude-build "$NIGHTLY_BUILD" \
  --count "$RECENT_BASES" \
  $(printf -- '--older-than-hours %s ' "${OLDER_BASE_HOURS[@]}") \
  --out "$previous" \
  --dates-out "$previous_dates"

if ! compgen -G "$previous/*.dmg" >/dev/null; then
  echo "No previous $NIGHTLY_VARIANT archive; retaining the full-only appcast"
  cp "$FULL_FEED" "$OUT_DIR/$feed"
  exit 0
fi
SPARKLE_PRIVATE_KEY="$("$scripts_dir/ci/nightly-sparkle-key.sh")"
export SPARKLE_PRIVATE_KEY
SPARKLE_PUBLIC_KEY="$(
  printf '%s' "$SPARKLE_PRIVATE_KEY" |
    env -u SPARKLE_PRIVATE_KEY \
      -u SHARED_SPARKLE_PRIVATE_KEY \
      -u NIGHTLY_SPARKLE_PRIVATE_KEY \
      -u NEXT_SPARKLE_PRIVATE_KEY \
      swift "$scripts_dir/derive_sparkle_public_key.swift" --stdin
)"
export SPARKLE_PUBLIC_KEY
"$scripts_dir/ci/drop-previous-nightlies-with-other-sparkle-key.sh" "$previous" "$SPARKLE_PUBLIC_KEY"
# The full feed's item for this DMG already carries the bundle's macOS floor
# (appcast_minimum_system_version.py floor); keep it.
SPARKLE_MINIMUM_SYSTEM_VERSION="$(python3 - "$FULL_FEED" "$(basename "$DMG")" <<'PY'
import re, sys
feed, archive = sys.argv[1], sys.argv[2]
for item in re.findall(r"<item>.*?</item>", open(feed, encoding="utf-8").read(), re.S):
    if archive in item:
        m = re.search(r"<sparkle:minimumSystemVersion>\s*([^<]*?)\s*</sparkle:minimumSystemVersion>", item)
        if m:
            print(m.group(1))
            sys.exit(0)
sys.exit(f"no sparkle:minimumSystemVersion for {archive} in {feed}")
PY
)"
export SPARKLE_MINIMUM_SYSTEM_VERSION
SPARKLE_PREVIOUS_ARCHIVES_DIR="$previous" \
SPARKLE_MAXIMUM_DELTAS="$(find "$previous" -maxdepth 1 -name '*.dmg' | wc -l | tr -d ' ')" \
SPARKLE_DELTA_NAME_PREFIX="${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-" \
  "$scripts_dir/sparkle_generate_appcast.sh" "$DMG" "$CHANNEL_RELEASE_TAG" "$OUT_DIR/$feed"
# generate_appcast rewrites the items; keep the full feed's changelog
# <description> for this build (cx-lntk).
python3 "$scripts_dir/ci/appcast_carry_description.py" "$FULL_FEED" "$OUT_DIR/$feed" "$NIGHTLY_BUILD"
# generate_appcast dates every item by its archive's mtime, so each item would
# get this run's time. Keep each build's first-publish date: this build's from
# the full feed it was published with, earlier builds' from their upload time.
python3 "$scripts_dir/ci/appcast_keep_pubdates.py" "$OUT_DIR/$feed" --feed "$FULL_FEED" --dates "$previous_dates"
