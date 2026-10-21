// A thought dates its first and latest chunk, so an ended thought can say how long the agent
// thought ("Thought for 12s", PR #20963). The parent transcript and a subagent's own view both
// stream thoughts through appendThought.
import { expect, test } from "bun:test";
import { appendThought } from "./direct";
import { childRows } from "./subagents/childRows";

test("a thought's first chunk dates its start and each later chunk its end", () => {
  let items = appendThought([], "Reading ", 1_000);
  expect(items).toEqual([{ kind: "thought", text: "Reading ", startedAt: 1_000, endedAt: 1_000 }]);
  items = appendThought(items, "the file", 13_000);
  expect(items).toEqual([{ kind: "thought", text: "Reading the file", startedAt: 1_000, endedAt: 13_000 }]);
});

test("a thought after a tool call starts its own clock", () => {
  const tool = { kind: "tool", text: "Read", tool: { id: "t1", title: "Read", kind: "read", status: "completed" } };
  const items = appendThought([...appendThought([], "first", 1_000), tool], "second", 20_000);
  expect(items.at(-1)).toEqual({ kind: "thought", text: "second", startedAt: 20_000, endedAt: 20_000 });
  expect(items[0]).toEqual({ kind: "thought", text: "first", startedAt: 1_000, endedAt: 1_000 });
});

test("a chunk with no time keeps the thought's dates as they were", () => {
  expect(appendThought([], "undated")).toEqual([{ kind: "thought", text: "undated" }]);
  const items = appendThought(appendThought([], "a", 5_000), "b");
  expect(items).toEqual([{ kind: "thought", text: "ab", startedAt: 5_000, endedAt: 5_000 }]);
});

test("a subagent's thought dates its chunks from their events", () => {
  const chunk = (seq: number, at: number, text: string) => ({
    event: { seq, at },
    update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text } },
  });
  const rows = childRows("child", [chunk(1, 2_000, "Plan"), chunk(2, 9_000, "ning")], new Map(), 1);
  expect(rows).toHaveLength(1);
  expect(rows[0]!.items).toEqual([{ kind: "thought", text: "Planning", startedAt: 2_000, endedAt: 9_000 }]);
});
