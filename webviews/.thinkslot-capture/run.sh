#!/usr/bin/env bash
# Scratch (not committed): the live spot's every status, after (this tree) and before (base's live-line code).
set -uo pipefail
cd "$(dirname "$0")/.."
out="${FAST_CHECKS_OUT:-/tmp/thinkslot-out}"
mkdir -p "$out"
base="$1"
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .thinkslot-capture/spec.json "$out/after" || echo "after capture failed"
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch --depth=1 origin "$base" || echo "fetch failed"
for f in src/agent-session/acpmux/conversation/Thinking.tsx src/agent-session/acpmux/conversation/ActivityLine.tsx \
  src/agent-session/acpmux/conversation/compactingLine.experiment.ts src/agent-session/acpmux/conversation/conversation.css \
  src/agent-session/acpmux/conversation/turns.ts src/agent-session/acpmux/model.ts src/agent-session/acpmux/rows/ThinkingRow.tsx; do
  git show "$base:webviews/$f" > "$f" || echo "show failed $f"
done
# Base has no SHIMMER_CLASS export; the gallery does not import it.
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .thinkslot-capture/spec.json "$out/before" || echo "before capture failed"
find "$out" -name '*.png' | sort
