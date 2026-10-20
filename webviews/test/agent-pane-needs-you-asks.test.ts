// Needs you's asks (needsYou/asks.ts) are acpmux's pending permission requests in every watched
// chat. An ask answered anywhere (its card, the Feed, `acpmux session allow`, another pane) must
// leave the list: a count of zero clears the chat at once, a count the page cannot account for or
// an answer rereads `_acpmux/info`, and a read that predates a newer ask or a newer read is dropped,
// so a slow read never brings back an answered ask or drops a new one.
import { expect, test } from "bun:test";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { AskTracker, type PendingEntry } from "../src/agent-session/acpmux/needsYou/asks";

const parse = (message: unknown, sessionId: string): AcpmuxPermission | undefined => {
  const id = (message as { permissionId?: unknown }).permissionId;
  return typeof id === "string" ? { permissionId: id, pending: true, options: [], title: `${sessionId}:${id}` } : undefined;
};

type Read = { sessionId: string; resolve(entries: readonly PendingEntry[] | undefined): void };

function tracker(now = () => 1000) {
  const reads: Read[] = [];
  let changes = 0;
  const asks = new AskTracker(
    (sessionId) => new Promise((resolve) => reads.push({ sessionId, resolve })),
    parse,
    () => void changes++,
    now,
  );
  return { asks, reads, changes: () => changes };
}
const ids = (asks: AskTracker) => asks.list().map((ask) => ask.permission.permissionId);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a pending notification adds an ask once, and the list keeps its identity until a change", () => {
  const { asks, changes } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  expect(ids(asks)).toEqual(["p1"]);
  expect(changes()).toBe(1);
  expect(asks.list()).toBe(asks.list());
  expect(asks.list()[0]!.at).toBe(1000);
});

test("a count of zero clears the chat's asks with no read", () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.pending({ sessionId: "s2", permissionId: "p2" });
  asks.session({ sessionId: "s1", pendingPermissions: 0 });
  expect(ids(asks)).toEqual(["p2"]);
  expect(reads).toHaveLength(0);
});

test("an answer elsewhere rereads the chat, and the read's list wins", async () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  // The count still reads 1 (a new ask took the answered one's place), but the change is an answer.
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "permission_decision");
  expect(reads).toHaveLength(1);
  reads[0]!.resolve([{ permissionId: "p3", request: {}, turnId: "t3" }]);
  await settle();
  expect(ids(asks)).toEqual(["p3"]);
  expect(asks.list()[0]!.permission.turnId).toBe("t3");
});

test("a count that matches what the page holds needs no read", () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "status");
  expect(reads).toHaveLength(0);
});

test("asks found by a read (opened before the page saw them) are dated by the chat's last change", async () => {
  const { asks, reads } = tracker(() => 5000);
  asks.sessions([{ sessionId: "s1", pendingPermissions: 2, updatedAt: 1200 }]);
  reads[0]!.resolve([{ permissionId: "a" }, { permissionId: "b" }]);
  await settle();
  expect(ids(asks)).toEqual(["a", "b"]);
  expect(asks.list().map((ask) => ask.at)).toEqual([1200, 1200]);
});

test("a read that predates a newer ask or a newer read is dropped", async () => {
  const { asks, reads } = tracker();
  asks.session({ sessionId: "s1", pendingPermissions: 1 });
  // The ask arrives while the first read is out: that read may not include it.
  asks.pending({ sessionId: "s1", permissionId: "new" });
  reads[0]!.resolve([]);
  await settle();
  expect(ids(asks)).toEqual(["new"]);
  // Two reads out at once: only the newer counts, however they land.
  asks.session({ sessionId: "s1", pendingPermissions: 2 });
  asks.session({ sessionId: "s1", pendingPermissions: 2 }, "permission_resolved");
  reads[2]!.resolve([{ permissionId: "new" }, { permissionId: "late" }]);
  await settle();
  reads[1]!.resolve([]);
  await settle();
  expect(ids(asks)).toEqual(["new", "late"]);
});

test("a read that fails, or a chat that cannot be read, keeps what the page holds; a purge drops it", async () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.session({ sessionId: "s1", pendingPermissions: 2 });
  reads[0]!.resolve(undefined);
  await settle();
  expect(ids(asks)).toEqual(["p1"]);
  asks.forget("s1");
  expect(ids(asks)).toEqual([]);
});
