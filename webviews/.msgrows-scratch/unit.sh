#!/usr/bin/env bash
cd "$(dirname "$0")/.."
bun test src/agent-session/acpmux/conversation/SentMessageLine.test.tsx src/agent-session/acpmux/conversation/RowGrammar.test.tsx src/agent-session/acpmux/conversation/activityTone.test.ts src/agent-session/acpmux/rowEstimates.test.ts test/incoming-minimal-collapse.test.tsx test/lane-notice-card.test.tsx test/queue-agent-message.test.tsx test/transcript-row-message.test.tsx 2>&1 | tail -60
echo "== unit exit ${PIPESTATUS[0]}"
npx tsc -p . --noEmit 2>&1 | tail -20; echo "== tsc exit ${PIPESTATUS[0]}"
