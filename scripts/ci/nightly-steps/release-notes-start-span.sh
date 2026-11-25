#!/usr/bin/env bash
# nightly.yml sign-release-notes: "Start the span at the newest published notes". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
since=""
index="$(mktemp)"
if curl -fsSL -A "cmux-release-notes/1" -o "$index" "$NIGHTLY_NEXT_FEED_BASE/notes/index.json" \
   && curl -fsSL -A "cmux-release-notes/1" -o "$index.sig" "$NIGHTLY_NEXT_FEED_BASE/notes/index.json.sig" \
   && python3 scripts/cmux-next/release-notes.py verify --public-key "$CONTENT_PUBLIC_KEY" "$index"; then
  since="$(python3 scripts/cmux-next/release-notes.py since --index "$index" --not "$HEAD_SHA")"
fi
rm -f "$index" "$index.sig"
echo "since=${since:-${PUBLISHED_SHA:-}}" >> "$GITHUB_OUTPUT"
