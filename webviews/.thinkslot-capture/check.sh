#!/usr/bin/env bash
# Scratch (not committed): checks, the tests, the after shot.
set -uo pipefail
cd "$(dirname "$0")/.."
out="${FAST_CHECKS_OUT:-/tmp/thinkslot-out}"
mkdir -p "$out"
rc=0
bun run typecheck 2>&1 | tail -30 || rc=1
bun run check:catalog-keys 2>&1 | tail -5 || rc=1
bun run check:catalog-unused 2>&1 | tail -5 || rc=1
bun run check:type-scale 2>&1 | tail -5 || rc=1
bun test test/live-spot-one-shimmer.test.tsx src/agent-session/acpmux/conversation/BackgroundMark.test.tsx \
  src/agent-session/acpmux/conversation/Thinking.test.tsx test/agent-pane-chat-column.test.ts \
  test/agent-pane-subagent-groups-open.test.ts test/subagent-corner-dots.test.tsx \
  test/subagent-tray.test.tsx test/summary-background-work.test.tsx test/transcript-live-line-call-done.test.tsx \
  test/transcript-live-line-state.test.tsx test/transcript-live-line-step-time.test.tsx \
  test/transcript-live-line-true-state.test.tsx test/tray-command-titles.test.ts test/transcript-turn-retry.test.tsx \
  test/live-line-needs-input-pill.test.tsx test/session-info.test.tsx test/waiting-on-you-row-renders.test.tsx \
  src/agent-session/acpmux/conversation/backgroundRuns.test.tsx src/agent-session/acpmux/conversation/backgroundTurnInline.test.ts \
  src/agent-session/acpmux/conversation/backgroundTurns.test.tsx test/agent-pane-background-turns.test.ts \
  > "$out/tests.txt" 2>&1 || rc=1
grep -vE "^\s*\(pass\)|^✓" "$out/tests.txt" | grep -B40 -A3 "^(fail)\|^error" | head -300
tail -4 "$out/tests.txt"
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .thinkslot-capture/spec.json "$out/after" 2>&1 | tail -3
exit $rc
