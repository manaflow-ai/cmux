set -e
cd webviews
bun test src/agent-session/acpmux/lostPromptRow.test.ts src/agent-session/acpmux/conversation/sendStateCoherence.test.tsx src/agent-session/acpmux/conversation/UserBubble.test.tsx src/agent-session/acpmux/reconnectPrompt.test.ts src/agent-session/acpmux/sendHeldWhileLoading.test.ts src/agent-session/acpmux/lostPrompt.test.ts src/agent-session/acpmux/promptDelivery.test.ts src/agent-session/acpmux/conversation/PromptDelivery.test.tsx 2>&1
bunx tsc -p . --noEmit
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .capture-still-sending.json "$FAST_CHECKS_OUT/after"
git -C .. stash push -q --include-untracked -- webviews/src webviews/test plans
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs .capture-still-sending-before.json "$FAST_CHECKS_OUT/before"
