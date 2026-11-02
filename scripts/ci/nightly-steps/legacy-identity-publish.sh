#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Publish the cmux NIGHTLY DMG, release notes and the old feed".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -euo pipefail
prefix="${NIGHTLY_NEXT_LEGACY_FEED_BASE#https://files-next.cmux.com/}"
[ "$prefix" = nightly-next ] || { echo "unexpected old feed base $NIGHTLY_NEXT_LEGACY_FEED_BASE" >&2; exit 1; }
upload() {  # <file> <key> <content-type> <cache-control>
  NIGHTLY_NEXT_R2_PREFIX="$prefix/" python3 scripts/ci/nightly-next-guard.py r2-key "$NIGHTLY_NEXT_R2_BUCKET" "$2"
  python3 scripts/ci/upload-r2-object.py --file "$1" --endpoint-url "$R2_ENDPOINT" \
    --bucket "$NIGHTLY_NEXT_R2_BUCKET" --key "$2" --content-type "$3" --cache-control "$4"
}
dmg="legacy-out/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
gh release upload "$CHANNEL_RELEASE_TAG" "$dmg" --repo "$GITHUB_REPOSITORY" --clobber
# The appcast goes live only after its DMG is downloadable.
url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${CHANNEL_RELEASE_TAG}/$(basename "$dmg")"
curl -fsSIL --retry 5 --retry-all-errors --retry-delay 5 -o /dev/null "$url"
# Signed release notes sit beside each appcast (ReleaseNotesStore):
# copy cmux NEXT's index and this build's notes, already signed, next
# to the old feed. Best effort: a notes problem never blocks the feed.
copy_notes() {
  local src="${NIGHTLY_NEXT_FEED_BASE}/notes" name
  mkdir -p legacy-notes
  for name in index.json "${NIGHTLY_BUILD}.json"; do
    curl -fsSL --retry 3 -o "legacy-notes/$name" "$src/$name" || return 1
    curl -fsSL --retry 3 -o "legacy-notes/$name.sig" "$src/$name.sig" || return 1
  done
  # This build's notes first, the index (which names it) last.
  for name in "${NIGHTLY_BUILD}.json" index.json; do
    case "$name" in index.json) cache="no-cache, no-store, must-revalidate" ;; *) cache="public, max-age=3600" ;; esac
    upload "legacy-notes/$name" "$prefix/notes/$name" application/json "$cache" || return 1
    upload "legacy-notes/$name.sig" "$prefix/notes/$name.sig" text/plain "$cache" || return 1
  done
}
copy_notes || echo "::warning::release notes of build $NIGHTLY_BUILD were not copied next to the old feed; the feed is still published"
upload "legacy-out/$LEGACY_APPCAST" "$prefix/$LEGACY_APPCAST" application/xml "no-cache, no-store, must-revalidate"
# Release push for cmux NIGHTLY, once the old feed is written: the presence
# worker re-reads it and tells connected NIGHTLY apps at once, as
# publish-nightly's poke does for cmux NEXT's feed. No secret (it only reads an
# allowlisted public appcast, and a build only moves up). Best effort: a failure
# warns and never fails the publish; the worker's minute cron catches up.
# RELEASE_POKE_URL comes from the step env, so a run without it calls nothing.
if [[ -n "${RELEASE_POKE_URL:-}" ]]; then
  if status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST --max-time 10 --retry 3 "$RELEASE_POKE_URL")" \
    && [[ "$status" == 2?? ]]; then
    echo "release poke accepted: HTTP $status ($RELEASE_POKE_URL)"
  else
    echo "::warning::release poke failed (HTTP ${status:-none}); the minute cron will catch up"
  fi
fi
# Keep the three newest cmux NIGHTLY-identity DMGs, never one the feed names.
gh release view "$CHANNEL_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' \
  | python3 -I -c 'import re, sys; p = re.compile("^" + re.escape(sys.argv[1]) + r"(\d+)\.dmg$"); keep = {int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", open(sys.argv[2], encoding="utf-8").read())}; names = sorted((int(m.group(1)), n) for n in sys.stdin.read().split() if (m := p.match(n))); [print(n) for b, n in names[:-3] if b not in keep]' "$LEGACY_DMG_PREFIX" "legacy-out/$LEGACY_APPCAST" \
  | while IFS= read -r old; do
      gh release delete-asset "$CHANNEL_RELEASE_TAG" "$old" --repo "$GITHUB_REPOSITORY" --yes || true
    done
{
  echo "### cmux NIGHTLY-identity build ${NIGHTLY_BUILD} published (cx-x7hwx)"
  echo ""
  echo "- feed: ${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
  echo "- DMG: $url"
} >> "$GITHUB_STEP_SUMMARY"
