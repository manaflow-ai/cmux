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
mkdir -p notes
# Extend the published index only when its signature verifies. It is read before the build so the
# notes' `since` can name the build whose head the span starts at.
previous=""
# The retired cmux NEXT-identity feed's notes are the fallback history.
for base in "${NIGHTLY_NEXT_FEED_BASE}" "${NIGHTLY_NEXT_RETIRED_FEED_BASE}"; do
  if curl -fsSL -A "cmux-release-notes/1" -o notes/previous-index.json "$base/notes/index.json" \
     && curl -fsSL -A "cmux-release-notes/1" -o notes/previous-index.json.sig "$base/notes/index.json.sig" \
     && python3 scripts/cmux-next/release-notes.py verify --public-key "$CONTENT_PUBLIC_KEY" notes/previous-index.json; then
    previous=notes/previous-index.json
    break
  fi
done
python3 scripts/cmux-next/release-notes.py build --build "$NIGHTLY_BUILD" \
  --short "$NIGHTLY_VERSION" --date "$(date -u +%Y-%m-%d)" \
  --published-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ${previous:+--previous-index "$previous"} \
  --head "$HEAD_SHA" --since "$since" --out notes --pr-media --pr-descriptions
python3 scripts/cmux-next/release-notes.py index --notes "notes/$NIGHTLY_BUILD.json" \
  ${previous:+--previous "$previous"} --out notes/index.json
# Announcement cards (R114): the reviewed release-notes/next/announcements.json, when present.
signed=("notes/$NIGHTLY_BUILD.json" notes/index.json)
# notes/pr-index.json: each PR number to the first build that shipped it, merged into the
# published (verified) copy. A first publish (404) seeds it from the notes the index lists; any
# other failure to read or verify it skips it, so a bad fetch never overwrites the history.
pr_status="$(curl -sSL -A "cmux-release-notes/1" -o notes/previous-pr-index.json -w '%{http_code}' \
  "$NIGHTLY_NEXT_FEED_BASE/notes/pr-index.json" || true)"
pr_args=()
if [ "$pr_status" = 200 ] \
   && curl -fsSL -A "cmux-release-notes/1" -o notes/previous-pr-index.json.sig "$NIGHTLY_NEXT_FEED_BASE/notes/pr-index.json.sig" \
   && python3 scripts/cmux-next/release-notes.py verify --public-key "$CONTENT_PUBLIC_KEY" notes/previous-pr-index.json; then
  pr_args=(--previous notes/previous-pr-index.json)
elif [ "$pr_status" = 404 ]; then
  pr_args=(--seed-index notes/index.json --base "$NIGHTLY_NEXT_FEED_BASE" --base "$NIGHTLY_NEXT_RETIRED_FEED_BASE"
    --public-key "$CONTENT_PUBLIC_KEY")
else
  echo "::warning::notes/pr-index.json did not read or verify (HTTP $pr_status); this build publishes without it"
fi
if [ "${#pr_args[@]}" -gt 0 ]; then
  python3 scripts/cmux-next/release-notes.py pr-index --notes "notes/$NIGHTLY_BUILD.json" \
    "${pr_args[@]}" --out notes/pr-index.json
  signed+=(notes/pr-index.json)
fi
rm -f notes/previous-index.json notes/previous-index.json.sig notes/previous-pr-index.json notes/previous-pr-index.json.sig
# Older published notes without summary lines or structured items get them (cx-urd.61.6):
# fetched from either feed, verified, filled from their commit subjects, re-signed below and
# uploaded with this build's notes. Builds already carrying both are left alone.
# The files are written apart and join notes/ only when the whole backfill succeeded, so a
# crash can never upload rewritten notes without their new signatures.
backfill_dir="$(mktemp -d)"
if listed="$(python3 scripts/cmux-next/release-notes.py backfill --index notes/index.json \
     --base "$NIGHTLY_NEXT_FEED_BASE" --base "$NIGHTLY_NEXT_RETIRED_FEED_BASE" \
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
# The handover card for the retired cmux NEXT-identity feed (com.cmuxterm.app.nightly.cmux-next):
# Sparkle cannot move an install to another bundle id, and the app has no informational update,
# so a stray cmux NEXT install learns from this card where its builds went (hq#7156).
# release-notes-upload-to-r2.sh writes it beside that feed as notes/announcements.json.
if [ -f release-notes/next/retired-feed-announcements.json ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("version")==1 and isinstance(d.get("items"),list) and d["items"]' release-notes/next/retired-feed-announcements.json
  cp release-notes/next/retired-feed-announcements.json notes/retired-feed-announcements.json
  signed+=(notes/retired-feed-announcements.json)
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
