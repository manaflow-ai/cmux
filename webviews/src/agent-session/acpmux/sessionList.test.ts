import { expect, test } from "bun:test";
import { groupByProject, sidebarSections, sessionEntry } from "./sessionList";

const entry = (sessionId: string, extra: Record<string, unknown> = {}) =>
  sessionEntry({ sessionId, name: sessionId, updatedAt: 1, ...extra });

test("sidebar groups chats by folder while keeping pinned chats outside groups", () => {
  const [pinned, local, cloud] = [
    entry("pinned", { pinned: true, cwd: "/Users/leo/cmux" }),
    entry("local", { cwd: "/Users/leo/cmux" }),
    entry("cloud", { cwd: "/workspace/cmux", hostKind: "cloud", peer: "builder" }),
  ];
  const result = sidebarSections([pinned, local, cloud]);
  expect(result.pinned.map(({ sessionId }) => sessionId)).toEqual(["pinned"]);
  expect(result.groups.map(({ label, sessions }) => [label, sessions.map(({ sessionId }) => sessionId)])).toEqual([
    ["cmux", ["local"]],
    ["cmux", ["cloud"]],
  ]);
});

test("cloud chats on the same folder stay in one group when they share a host", () => {
  const chats = [
    entry("one", { cwd: "/workspace/cmux", hostKind: "cloud", peer: "builder", updatedAt: 2 }),
    entry("two", { cwd: "/workspace/cmux", hostKind: "cloud", peer: "builder", updatedAt: 1 }),
  ];
  const groups = groupByProject(chats);
  expect(groups).toHaveLength(1);
  expect(groups[0]?.host).toBe("builder");
  expect(groups[0]?.sessions.map(({ sessionId }) => sessionId)).toEqual(["one", "two"]);
});
