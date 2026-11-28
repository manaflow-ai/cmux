#!/usr/bin/env bash
# nightly.yml nightly-next-variant-from-r2: "Rebuild the variant artifact from R2".
# Why: docs/ci/nightly-workflow-notes/2026-11-27-variant-from-r2.md
# Once nightly-next-one writes the feed, its DMG is already on R2 (read back by SHA-256 before the feed).
# The signing Mac then uploads only the feed files (appcasts and deltas, cmux-nightly-feed-files-arm64);
# this job reads the DMG back from R2, requires the tested digest, and makes cmux-nightly-variant-arm64
# with the same files the Mac used to upload, so every reader is unchanged.
# Env: CHANNEL_DMG_PREFIX, NIGHTLY_BUILD, NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX, R2_ENDPOINT,
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, PUBLISH_TOOLING; FEED_FILES, TESTED, OUT (dirs);
# R2_DOWNLOAD (test override for the downloader).
set -euo pipefail
[[ "$NIGHTLY_BUILD" =~ ^[0-9]+$ && "$CHANNEL_DMG_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "invalid build '$NIGHTLY_BUILD' or prefix '$CHANNEL_DMG_PREFIX'" >&2; exit 1; }
dmg="${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
mkdir -p "$OUT"
download=(python3 "$PUBLISH_TOOLING/ci/upload-r2-object.py")
[ -z "${R2_DOWNLOAD:-}" ] || download=("$R2_DOWNLOAD")
"${download[@]}" --endpoint-url "$R2_ENDPOINT" \
  --bucket "$NIGHTLY_NEXT_R2_BUCKET" --key "${NIGHTLY_NEXT_R2_PREFIX}${dmg}" --download-to "$OUT/$dmg"
actual="$(shasum -a 256 "$OUT/$dmg" | awk '{print $1}')"
cat "$TESTED"/*.sha256 | grep -Fxq "$actual  $dmg" || { echo "$dmg ($actual) on R2 is not the tested DMG" >&2; exit 1; }
for file in "$FEED_FILES"/*; do
  [ -f "$file" ] && [ ! -L "$file" ] || { echo "unexpected feed file $file" >&2; exit 1; }
  case "$(basename "$file")" in *.dmg) echo "the feed files carry a DMG: $file" >&2; exit 1;; esac
  cp "$file" "$OUT/"
done
echo "$dmg ($actual) from R2 matches the tested digest; $(ls "$OUT" | wc -l | tr -d ' ') files in the variant artifact"
