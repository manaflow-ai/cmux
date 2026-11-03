#!/usr/bin/env bash
# Moved out of .github/workflows/nightly.yml (size cap); the step's env is unchanged.
set -euo pipefail
# The previous published commit. publish-nightly has already moved the
# nightly-next tag to HEAD_SHA when this job runs, so the tag gave an
# empty span and every build shipped "changes": [] (cx-lntk); the tag
# is only the fallback when decide recorded no published commit.
since="${SPAN_SINCE:-${PUBLISHED_SHA:-}}"
if [ -z "$since" ]; then
  since="$(git rev-parse -q --verify 'refs/tags/nightly-next^{commit}' || true)"
fi
if [ "$since" = "$HEAD_SHA" ]; then since=""; fi
python3 scripts/cmux-next/release-notes.py build --build "$NIGHTLY_BUILD" \
  --short "$NIGHTLY_VERSION" --date "$(date -u +%Y-%m-%d)" \
  --head "$HEAD_SHA" --since "$since" --out notes --pr-media --pr-descriptions
# Extend the published index only when its signature verifies.
previous=""
# The first cmux NEXT build carries the history over from the old feed.
for base in "${NIGHTLY_NEXT_FEED_BASE}" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}"; do
  if curl -fsSL -A "cmux-release-notes/1" -o notes/previous-index.json "$base/notes/index.json" \
     && curl -fsSL -A "cmux-release-notes/1" -o notes/previous-index.json.sig "$base/notes/index.json.sig" \
     && python3 scripts/cmux-next/release-notes.py verify --public-key "$CONTENT_PUBLIC_KEY" notes/previous-index.json; then
    previous=notes/previous-index.json
    break
  fi
done
python3 scripts/cmux-next/release-notes.py index --notes "notes/$NIGHTLY_BUILD.json" \
  ${previous:+--previous "$previous"} --out notes/index.json
rm -f notes/previous-index.json notes/previous-index.json.sig
# Announcement cards (R114): the reviewed release-notes/next/announcements.json, when present.
signed=("notes/$NIGHTLY_BUILD.json" notes/index.json)
# Older published notes without summary lines or structured items get them (cx-urd.61.6):
# fetched from either feed, verified, filled from their commit subjects, re-signed below and
# uploaded with this build's notes. Builds already carrying both are left alone.
# The files are written apart and join notes/ only when the whole backfill succeeded, so a
# crash can never upload rewritten notes without their new signatures.
backfill_dir="$(mktemp -d)"
if listed="$(python3 scripts/cmux-next/release-notes.py backfill --index notes/index.json \
     --base "$NIGHTLY_NEXT_FEED_BASE" --base "$NIGHTLY_NEXT_LEGACY_FEED_BASE" \
     --public-key "$CONTENT_PUBLIC_KEY" --out "$backfill_dir" --existing notes)"; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    mv "$file" "notes/$(basename "$file")"
    signed+=("notes/$(basename "$file")")
  done <<< "$listed"
else
  echo "::warning::release notes backfill failed; this build's notes publish without it"
fi
rm -rf "$backfill_dir"
if [ -f release-notes/next/announcements.json ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("version")==1 and isinstance(d.get("items"),list)' release-notes/next/announcements.json
  cp release-notes/next/announcements.json notes/announcements.json
  signed+=(notes/announcements.json)
fi
# Invite-wave flags for cmux-tui testers (tui-tester-rollout #10): the reviewed
# release-notes/next/flags.json, signed with the same content-signing key.
if [ -f release-notes/next/flags.json ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert type(d.get("version")) is int and d["version"]==1 and isinstance(d.get("default"),dict) and isinstance(d.get("cohorts"),dict) and all(isinstance(v,dict) and isinstance(v.get("DisabledFeatures",[]),list) for v in [d["default"], *d["cohorts"].values()])' release-notes/next/flags.json
  cp release-notes/next/flags.json notes/flags.json
  signed+=(notes/flags.json)
fi
key="$(mktemp)"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$CONTENT_SIGNING_ED25519_PEM" > "$key"
python3 scripts/cmux-next/release-notes.py sign --key "$key" "${signed[@]}"
for f in "${signed[@]}"; do
  python3 scripts/cmux-next/release-notes.py verify --public-key "$CONTENT_PUBLIC_KEY" "$f"
done
