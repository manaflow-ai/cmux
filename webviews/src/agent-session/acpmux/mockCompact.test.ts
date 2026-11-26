// The mock daemon compacts on `/compact` as Claude Code does (running, again, then its end), so snappy-bench can
// count the layout shifts of a compaction (Leo 2026-11-25: "layout shifts and awkward looking animations").
import { expect, test } from "bun:test";
import { mockTurn } from "./mock";

test("/compact is a compaction: running twice, then completed with its sizes", () => {
  const states = mockTurn("/compact keep the plan", 3).map((step) => ("update" in step ? step.update : {}));
  expect(states.map((update) => [update.sessionUpdate, update.state])).toEqual([
    ["compaction", "running"],
    ["compaction", "running"],
    ["compaction", "completed"],
  ]);
  expect(states[2]).toMatchObject({ preTokens: 152_000, postTokens: 18_000 });
});

test("any other prompt is the scripted work turn", () => {
  expect(mockTurn("compact the list", 3)[0]).toEqual({
    update: {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "I'll look at the greeting helper" },
    },
  });
});
