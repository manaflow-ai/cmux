#!/usr/bin/env bash
# nightly.yml publish-nightly: "Prepare nightly release notes and appcast summaries".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The notes take seconds. Bounded here, a slow notes run fails before
# any asset upload instead of using up the job's time and being
# cancelled mid-upload (run 37611677848 left partial assets that way).
# 60 of these minutes are the most its gh calls may wait for a rate-limit
# reset (gh_budget_wait.sh); the job's timeout leaves 20 after them.
# nightly-next runs are pushes to nightly-next; their PRs merge into feat-cmux-next.
set -euo pipefail
read -ra feeds <<< "$NIGHTLY_FEEDS"
download="https://github.com/${GITHUB_REPOSITORY}/releases/download/${CHANNEL_RELEASE_TAG}"
arm64_line="- [Apple silicon: ${CHANNEL_DMG_PREFIX}-arm64.dmg](${download}/${CHANNEL_DMG_PREFIX}-arm64.dmg), feed \`appcast-arm64.xml\`"
if [ "$NIGHTLY_TRACK" = nightly-next ]; then
  downloads="**${NOTES_APP_NAME}** ships for Apple silicon only (bundle ID \`${NOTES_BUNDLE_ID}\`):
${arm64_line}"
else
  downloads="**${NOTES_APP_NAME}** ships one app per architecture (bundle ID \`${NOTES_BUNDLE_ID}\`):
${arm64_line}
- [Intel: ${CHANNEL_DMG_PREFIX}-x86_64.dmg](${download}/${CHANNEL_DMG_PREFIX}-x86_64.dmg), feed \`appcast-x86_64.xml\`
- [Universal (any Mac): ${CHANNEL_DMG_PREFIX}.dmg](${download}/${CHANNEL_DMG_PREFIX}.dmg), feed \`appcast.xml\`; the app switches to its architecture's feed on the first update check"
fi
# The release metadata steps below list the same downloads.
{
  echo "downloads<<CMUX_DOWNLOADS_EOF"
  printf '%s\n' "$downloads"
  echo "CMUX_DOWNLOADS_EOF"
} >> "$GITHUB_OUTPUT"
cat > nightly-downloads.md <<EOF
Automated ${CHANNEL} build for \`${NOTES_HEAD:0:7}\` from \`${NOTES_BRANCH}\`.
Published commit: \`${NOTES_HEAD}\`.
${downloads}
EOF
# Older builds on this rolling release bundle GNU libintl in the ghostty
# CLI helper; keep the LGPL source notice while the source is attached.
if gh release view "$CHANNEL_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets \
    -q '.assets[].name' | grep -qx 'gettext-0.24.tar.gz'; then
  cat >> nightly-downloads.md <<'EOF'

Nightly builds whose ghostty CLI helper contains GNU libintl from gettext 0.24 (LGPL-2.1-or-later) have the complete corresponding source and license text attached to this release (`gettext-0.24.tar.gz`, `COPYING.LIB`).
EOF
fi
# Read the live completed publication under the channel writer lock,
# rather than the decide job's baseline from before the build started.
# nightly_release_notes.py preserves the cmux-published-sha: marker
# used for the next exact range and its repair/recovery path.
python3 "$PUBLISH_TOOLING/ci/nightly_release_notes.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --head "$NOTES_HEAD" --branch "$NOTES_BRANCH" \
  --details nightly-downloads.md --out nightly-notes.md \
  --appcasts nightly-out --build "$NIGHTLY_BUILD" --feeds "${feeds[@]}"
# cmux-next lands commits, not PRs: its appcast item carries a short
# changelog of the user-facing commit subjects since the previous
# published build (New / Fixed / Changed, at most 8 lines, plain
# text; cx-lntk). The app shows the same lines from the signed notes.
if [ "$NIGHTLY_TRACK" = nightly-next ] && [ -n "$PUBLISHED_SHA" ] && [ "$PUBLISHED_SHA" != "$NOTES_HEAD" ]; then
  ./scripts/cmux-next/fetch-release-notes-span.sh origin "$NOTES_HEAD" nightly-next "$PUBLISHED_SHA"
  # The changelog gate (2026-10-20, Lawrence: "the change log needs to be better at all
  # times"): before any asset uploads, the span's What's New digest must validate, so a
  # malformed entry fails here. A span with nothing user-facing publishes the generic
  # "Fixes and improvements" entry with a warning (claude-sr2, 2026-10-27: that failure
  # threw away 9 of 79 notarized builds); sign-release-notes builds the same notes later.
  gate_dir="$(mktemp -d)"
  python3 scripts/cmux-next/release-notes.py build --build "$NIGHTLY_BUILD" \
    --short "1.0.0-nightly.$NIGHTLY_BUILD" --date "$(date -u +%Y-%m-%d)" \
    --head "$NOTES_HEAD" --since "$PUBLISHED_SHA" --out "$gate_dir" --pr-descriptions >/dev/null
  python3 scripts/cmux-next/release-notes.py check --notes "$gate_dir/$NIGHTLY_BUILD.json"
  rm -rf "$gate_dir"
  python3 scripts/cmux-next/release-notes.py appcast --head "$NOTES_HEAD" --since "$PUBLISHED_SHA" \
    --appcasts nightly-out --build "$NIGHTLY_BUILD" --feeds "${feeds[@]}"
  # The GitHub release body lists the same span's PRs (the two release
  # metadata steps below append it), so a nightly names what it contains.
  python3 scripts/cmux-next/release-notes.py prs --head "$NOTES_HEAD" --since "$PUBLISHED_SHA" \
    --repo "$GITHUB_REPOSITORY" > "$RUNNER_TEMP/nightly-prs.md"
fi
