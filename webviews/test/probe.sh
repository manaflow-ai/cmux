#!/usr/bin/env bash
cd webviews
st=0
bun test src/agent-session/acpmux/conversation/liveLineLast.test.ts src/agent-session/acpmux/conversation/Thinking.test.tsx test/claude-code-tool-rows.test.tsx test/transcript-live-line-below.test.tsx test/transcript-running-live-line.test.tsx test/transcript-codex-live-line.test.tsx test/transcript-live-line-state.test.tsx test/transcript-live-line-row-classes.test.tsx || st=1
CMUX_BROWSER_TESTS=1 bun test test/transcript-spacing-kinds.test.ts || st=1
CMUX_BROWSER_TESTS=1 bun test test/transcript-spacing-table.test.ts || st=1
CMUX_BROWSER_TESTS=1 bun test test/transcript-icon-column.test.ts || st=1
export PROBE_SCENES="agent-pane.transcript-spacing-table:working-bottom,agent-pane.transcript-spacing-table:notes-live,agent-pane.live-line-lead:mark,agent-pane.live-line-lead:mark-light,agent-pane.live-line-lead:mark-command,agent-pane.live-line-lead:slot,agent-pane.live-line-lead:flush"
bun test test/probe-turn-summary.test.ts || st=1
bun run check > "$FAST_CHECKS_OUT/check.log" 2>&1 || { echo CHECK FAILED; tail -60 "$FAST_CHECKS_OUT/check.log"; st=1; }
exit $st
