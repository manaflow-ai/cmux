// The New Tab's and the folder menu's recent folders are the folders the person picked: a chat an agent or a
// Chief started (its `startedBy`, `spawnedBy`, `chiefChild`, or a Chief's own turn) works in a folder of its own
// (a Chief's `session`, `tmp`), which listed as a recent folder of the person's (cmux#53226).
import { expect, test } from "bun:test";
import { FolderRecency, pickedFolder, type AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const entry = (sessionId: string, cwd: string, at: number, extra: Partial<AcpmuxSessionEntry> = {}) =>
  ({
    sessionId,
    cwd,
    harness: "claude",
    status: "ready",
    lastActivityAt: at,
    updatedAt: at,
    ...extra,
  }) as AcpmuxSessionEntry;

test("recent folders list only the chats the person started", () => {
  const recency = new FolderRecency(pickedFolder);
  const order = recency.of([
    entry("mine", "/Users/me/app", 1),
    entry("turn", "/Users/me/.cmux/chief/session", 5, { chiefTurn: { home: "h", participant: "p" } }),
    entry("chief", "/private/tmp", 4, { chiefChild: true }),
    entry("sub", "/Users/me/sub", 3, { startedBy: "mine" }),
    entry("spawn", "/Users/me/spawned", 2, { spawnedBy: "mine" }),
  ]);
  expect(order).toEqual(["/Users/me/app"]);
  expect(recency.usedAt("/private/tmp")).toBeUndefined();
});
