#!/usr/bin/env bash
# nightly.yml publish-release-notes: "Recheck the NEXT publication head". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
# The live NEXT feed is the order check: publish-nightly-next-github moves the
# nightly-next tag after the feed, off its path, so the tag can still name the
# previous build here. A newer build on the feed, or this one pulled by
# nightly-next-rollback.yml, skips the notes.
feed="$(mktemp)"
curl -fsSL --retry 3 -A "cmux-release-notes/1" -o "$feed" "$FEED_BASE/appcast-arm64.xml"
live_build="$(python3 - "$feed" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for item in root.iter():
    if item.tag.rsplit("}", 1)[-1] == "item":
        for child in item:
            if child.tag.rsplit("}", 1)[-1] == "version":
                print(child.text or "")
                raise SystemExit
raise SystemExit("missing appcast version")
PY
)"
if [[ "$live_build" =~ ^[0-9]+$ && "$EXPECTED_BUILD" =~ ^[0-9]+$ ]] && (( live_build != EXPECTED_BUILD )); then
  echo "::notice::Skipping release notes for build $EXPECTED_BUILD ($EXPECTED_SHA); NEXT feed serves $live_build"
  echo 'current=false' >> "$GITHUB_OUTPUT"
else
  echo 'current=true' >> "$GITHUB_OUTPUT"
fi
