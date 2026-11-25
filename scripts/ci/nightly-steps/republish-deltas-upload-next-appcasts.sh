#!/usr/bin/env bash
# nightly.yml republish-nightly-deltas: "Upload revised nightly-next appcasts to R2". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# As in publish-nightly: the nightly-next track writes only its own
# bucket prefix with its scoped token, after the guard checks each feed.
set -euo pipefail
r2=.publish-tooling/scripts/ci/publish-nightly-next-r2.py
# The deltas beside the DMG on R2, all at once; then every enclosure R2 serves at
# its length points there (an older build from before R2 keeps its release URL).
files=()
for delta in nightly-deltas/*.delta; do files+=(--file "$delta"); done
python3 "$r2" upload "${files[@]}"
for feed in nightly-deltas/appcast*.xml; do
  [ -f "$feed" ] || continue
  python3 "$r2" rewrite --feed "$feed" --if-public
  python3 .publish-tooling/scripts/ci/nightly-next-guard.py appcast "$feed"
  # Only while the live feed still serves this build (If-Match on the bytes read).
  python3 "$r2" write-feed --feed "$feed" --same-build
done
