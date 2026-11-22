import { expect, test } from "bun:test";
import { orderedSubagents } from "./subagentOrder";

type Agent = { id: string; parent: string | null; startedAt: number; priority: number };
const agent = (id: string, parent: string | null, priority: number, startedAt = 1): Agent => ({
  id,
  parent,
  priority,
  startedAt,
});

test("attention and recency order siblings without changing depth-first parentage", () => {
  const agents = [
    agent("parent", null, 1, 1),
    agent("finished", "parent", 2, 9),
    agent("working", "parent", 1, 10),
    agent("waiting", "parent", 0, 3),
    agent("waiting-new", "parent", 0, 12),
    agent("grandchild", "working", 0, 1),
  ];
  expect(orderedSubagents(agents, (a) => a.priority).map(({ agent: a, depth }) => [a.id, depth])).toEqual([
    ["parent", 0],
    ["waiting-new", 1],
    ["waiting", 1],
    ["working", 1],
    ["grandchild", 2],
    ["finished", 1],
  ]);
});

test("an absent parent and a self-parent stay visible at the root", () => {
  const agents = [agent("orphan", "gone", 2), agent("self", "self", 0), agent("child", "self", 1)];
  expect(orderedSubagents(agents, (a) => a.priority).map(({ agent: a, depth }) => [a.id, depth])).toEqual([
    ["self", 0],
    ["child", 1],
    ["orphan", 0],
  ]);
});

test("a historical parent cycle leaves every worker visible exactly once", () => {
  const agents = [agent("a", "b", 2), agent("b", "a", 0), agent("c", "a", 1), agent("d", null, 1)];
  const rows = orderedSubagents(agents, (a) => a.priority);
  expect(rows.map(({ agent: a }) => a.id)).toEqual(["d", "b", "a", "c"]);
  expect(rows.map((row) => row.depth)).toEqual([0, 0, 1, 2]);
  expect(new Set(rows.map(({ agent: a }) => a.id)).size).toBe(4);
});

test("a 300-agent chain uses one rank read per agent and no recursive call stack", () => {
  const agents = Array.from({ length: 300 }, (_, i) => agent(`a${i}`, i ? `a${i - 1}` : null, 1, i));
  let reads = 0;
  const rows = orderedSubagents(agents, (a) => {
    reads += 1;
    return a.priority;
  });
  expect(reads).toBe(300);
  expect(rows).toHaveLength(300);
  expect(rows[0]?.depth).toBe(0);
  expect(rows.at(-1)?.depth).toBe(299);
  expect(rows.at(-1)?.agent.id).toBe("a299");
});
