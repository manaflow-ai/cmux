import { expect, test } from "bun:test";
import type { AcpmuxPermission } from "../model";
import type { WatchedAsk } from "../needsYou/model";
import { childAsks } from "./childAsks";

const ask = (sessionId: string, permissionId: string, at: number): WatchedAsk => ({
  sessionId,
  at,
  permission: { permissionId, pending: true, options: [] } as unknown as AcpmuxPermission,
});

const sessions = [
  { sessionId: "parent" },
  { sessionId: "tests", startedBy: "parent", shortName: "tests", harness: "claude" },
  { sessionId: "lint", startedBy: "tests", shortName: "lint" },
  { sessionId: "other", startedBy: "elsewhere", shortName: "other" },
  { sessionId: "spawned", spawnedBy: "parent", name: "spawned" },
  { sessionId: "remote", startedBy: "parent", shortName: "remote", peer: "studio" },
  { sessionId: "loop-a", startedBy: "loop-b" },
  { sessionId: "loop-b", startedBy: "loop-a" },
];

test("a sub-session's ask shows in the chat above it, oldest first, named and placed", () => {
  const asks = [ask("lint", "p2", 20), ask("tests", "p1", 10), ask("parent", "own", 5)];
  const shown = childAsks(asks, sessions, "parent");
  expect(shown.map((child) => [child.ask.permission.permissionId, child.name, child.direct])).toEqual([
    ["p1", "tests", true],
    ["p2", "lint", false],
  ]);
  expect(shown[0]?.harness).toBe("claude");
  // The grandchild's own parent shows it as its direct child's.
  expect(childAsks(asks, sessions, "tests").map((child) => [child.name, child.direct])).toEqual([["lint", true]]);
});

test("never the chat's own ask, another family's, a spawned chat's, another computer's, or a loop", () => {
  const asks = [
    ask("parent", "own", 1),
    ask("other", "o", 2),
    ask("spawned", "s", 3),
    ask("remote", "r", 4),
    ask("loop-a", "l", 5),
    ask("unlisted", "u", 6),
  ];
  expect(childAsks(asks, sessions, "parent")).toEqual([]);
  expect(childAsks(asks, sessions, undefined)).toEqual([]);
});
