// l10n-allow-file: test fixture machine names, not shipped UI.
//
// The daemon's `_acpmux/peer_snapshot` reply as the pane reads it (peerCopy.ts): a tail it can draw
// at once, and what it keeps of the copy (its machine, generation and newest seq). These hold it
// to: no records or no machine is no copy; anything that is not a record is left out; a copy that
// starts at the chat's first record and was returned whole says the history is all there; a
// generation is the same only when both sides name the same one; and a down machine is told from
// another failure.
import { expect, test } from "bun:test";
import { peerBack, peerCopyTail, peerDown, sameGeneration } from "../src/agent-session/acpmux/peerCopy";

const record = (seq: number) => ({ sessionId: "m1", seq, at: seq * 1000, dir: "in", kind: "agent_message_chunk" });

test("a reply with no records or no machine is no copy", () => {
  expect(peerCopyTail(undefined, "m1")).toBeUndefined();
  expect(peerCopyTail({ peer: "huge-blue", events: [] }, "m1")).toBeUndefined();
  expect(peerCopyTail({ events: [record(1)] }, "m1")).toBeUndefined();
  expect(peerCopyTail({ peer: "huge-blue", events: [{ seq: "1", kind: "x" }, null] }, "m1")).toBeUndefined();
});

test("a whole copy from the first record says its history is all there", () => {
  const got = peerCopyTail(
    { peer: "huge-blue", events: [record(1), record(2)], hasMore: false, lastSeq: 2, generation: 42, capturedAt: 7 },
    "m1",
  )!;
  expect(got.tail.events.map((e) => e.seq)).toEqual([1, 2]);
  expect([got.tail.historyExhausted, got.tail.usageFromSeq]).toEqual([true, 0]);
  expect(got.copy).toEqual({
    sessionId: "m1",
    peer: "huge-blue",
    capturedAt: 7,
    generation: 42,
    lastSeq: 2,
    offline: false,
  });
});

test("a copy that leaves out older records, or held one that is not a record, is not whole", () => {
  const cut = peerCopyTail({ peer: "huge-blue", events: [record(5), record(6)], hasMore: true, lastSeq: 9 }, "m1")!;
  expect([cut.tail.historyExhausted, cut.tail.usageFromSeq, cut.copy.lastSeq]).toEqual([false, 5, 9]);
  expect(cut.copy.generation).toBeUndefined();
  const odd = peerCopyTail({ peer: "huge-blue", events: [record(1), { seq: 2 }], hasMore: false }, "m1")!;
  expect(odd.tail.events.map((e) => e.seq)).toEqual([1]);
  expect(odd.tail.historyExhausted).toBe(false);
  // The newest seq is never below a record it holds.
  expect(peerCopyTail({ peer: "huge-blue", events: [record(3)], lastSeq: 1 }, "m1")!.copy.lastSeq).toBe(3);
});

test("a generation is the same only when both name the same one", () => {
  expect(sameGeneration(42, 42)).toBe(true);
  expect(sameGeneration(42, 43)).toBe(false);
  expect(sameGeneration(undefined, 42)).toBe(false);
  expect(sameGeneration(42, undefined)).toBe(false);
  expect(sameGeneration("42", 42)).toBe(false);
});

test("a down machine is told from another failure, and a row that answers from one that does not", () => {
  expect(peerDown({ reason: "peer_unreachable" })).toBe(true);
  expect(peerDown(new Error("peer_unreachable: huge-blue"))).toBe(true);
  expect(peerDown(new Error("session not found"))).toBe(false);
  expect(peerDown(undefined)).toBe(false);
  expect(peerBack({ status: "idle" })).toBe(true);
  expect(peerBack({ status: "idle", stale: true })).toBe(false);
  expect(peerBack({ status: "unreachable" })).toBe(false);
  expect(peerBack(undefined)).toBe(false);
});
