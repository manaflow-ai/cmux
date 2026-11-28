import { expect, test } from "bun:test";
import { session } from "../../gallery/fixtures/acpmux";
import { createSettleWatch, isSettleUndoKey, settledShelf, settledToastText, settleReasonText } from "./settledChats";
import { noteReplaced } from "./sessionIndex";
import { type AcpmuxSessionEntry, sessionEntry, settleTags } from "./sessionList";

const DAY = 24 * 60 * 60 * 1000;
const NOW = 1_800_000_000_000;

test("settleTags reads the reason only on an archived chat, and the never override", () => {
  expect(settleTags({ archived: "1", settled: "merged" })).toEqual({ settled: "merged" });
  expect(settleTags({ archived: "1", settled: "idle", autoSettle: "never" })).toEqual({
    settled: "idle",
    autoSettle: "never",
  });
  // Un-settled: the archive went with the reason; a stale reason alone is no settle.
  expect(settleTags({ settled: "closed" })).toEqual({});
  // A newer acpmux's reason still reads as settled.
  expect(settleTags({ archived: "1", settled: "abandoned" })).toEqual({ settled: "manual" });
  expect(settleTags({ autoSettle: "sometimes" })).toEqual({});
  expect(settleTags(undefined)).toEqual({});
});

test("sessionEntry carries settled and autoSettle next to archived", () => {
  const entry = sessionEntry({ sessionId: "a", tags: { archived: "1", settled: "closed", autoSettle: "never" } });
  expect(entry.archived).toBe(true);
  expect(entry.settled).toBe("closed");
  expect(entry.autoSettle).toBe("never");
  const plain = sessionEntry({ sessionId: "b", tags: { archived: "1" } });
  expect(plain.archived).toBe(true);
  expect("settled" in plain).toBe(false);
});

const listedChat = (id: string, fields: Partial<AcpmuxSessionEntry> = {}) =>
  session({ sessionId: id, title: id, ...fields });
const settle = (entry: AcpmuxSessionEntry, settled: AcpmuxSessionEntry["settled"] = "merged") => ({
  ...entry,
  archived: true,
  settled,
});

test("the watch answers nothing on the first list, nor for chats already archived or first seen settled", () => {
  const watch = createSettleWatch();
  const first = [settle(listedChat("old")), listedChat("a")];
  expect(watch(first)).toEqual([]);
  // The same list again (a re-render) is no change.
  expect(watch(first)).toEqual([]);
  const archived = listedChat("archived", { archived: true });
  const second = [settle(listedChat("old")), listedChat("a"), archived, settle(listedChat("new"))];
  expect(watch(second)).toEqual([]);
  // An archived chat that gains a reason was not listed: no toast.
  expect(watch([settle(listedChat("old")), listedChat("a"), settle(archived), settle(listedChat("new"))])).toEqual([]);
});

test("the watch answers a listed chat that became settled, through a whole new list", () => {
  const watch = createSettleWatch();
  const a = listedChat("a");
  const b = listedChat("b");
  watch([a, b]);
  const settled = settle(b, "idle");
  expect(watch([a, settled])).toEqual([settled]);
  // Still settled on the next list: said once.
  expect(watch([a, settled])).toEqual([]);
  expect(watch([a, { ...settled }])).toEqual([]);
});

test("the watch reads only the replaced rows of a list made in place", () => {
  const watch = createSettleWatch();
  const before = [listedChat("a"), listedChat("b"), listedChat("c")];
  watch(before);
  const after = [before[0]!, settle(before[1]!), before[2]!];
  noteReplaced(before, after, [1]);
  expect(watch(after).map((entry) => entry.sessionId)).toEqual(["b"]);
});

test("the watch tells a peer's copy from this Mac's chat of the same id", () => {
  const watch = createSettleWatch();
  const local = listedChat("same");
  const remote = listedChat("same", { peer: "build-box" });
  watch([local, remote]);
  const remoteSettled = settle(remote, "closed");
  expect(watch([local, remoteSettled])).toEqual([remoteSettled]);
  // A side chat is never listed, so it never toasts.
  const side = listedChat("side", { side: true });
  watch([side]);
  expect(watch([settle(side)])).toEqual([]);
});

test("the toast says why: merged, closed, idle days, or nothing for a manual settle", () => {
  const chat = listedChat("x", { displayTitle: "Fix the cache", activityAt: NOW - 3 * DAY - 1000 });
  expect(settledToastText(settle(chat, "merged"), NOW)).toBe("Settled: Fix the cache — PR merged");
  expect(settledToastText(settle(chat, "closed"), NOW)).toBe("Settled: Fix the cache — PR closed");
  expect(settledToastText(settle(chat, "idle"), NOW)).toBe("Settled: Fix the cache — idle 3 days");
  expect(settleReasonText(settle({ ...chat, activityAt: NOW - DAY }, "idle"), NOW)).toBe("idle 1 day");
  expect(settledToastText(settle(chat, "manual"), NOW)).toBe("Settled: Fix the cache");
});

test("the shelf lists settled chats newest first, without side chats or the shown one", () => {
  const sessions = [
    settle(listedChat("older", { activityAt: NOW - 2 * DAY })),
    settle(listedChat("newer", { activityAt: NOW - DAY })),
    settle(listedChat("shown")),
    settle(listedChat("aside", { side: true })),
    listedChat("live"),
    listedChat("archived", { archived: true }),
  ];
  const shelf = settledShelf(sessions, "shown");
  expect(shelf.rows.map((entry) => entry.sessionId)).toEqual(["newer", "older"]);
  expect(shelf.total).toBe(2);
});

test("Cmd+Z or Ctrl+Z is Undo outside an editable field", () => {
  const key = (init: KeyboardEventInit, target?: unknown) =>
    ({
      key: "z",
      shiftKey: false,
      altKey: false,
      repeat: false,
      metaKey: false,
      ctrlKey: false,
      target,
      ...init,
    }) as KeyboardEvent;
  expect(isSettleUndoKey(key({ metaKey: true }))).toBe(true);
  expect(isSettleUndoKey(key({ ctrlKey: true }))).toBe(true);
  expect(isSettleUndoKey(key({ metaKey: true, shiftKey: true }))).toBe(false);
  expect(isSettleUndoKey(key({}))).toBe(false);
  const inField = { closest: () => ({ textContent: "" }) };
  const outside = { closest: () => null };
  expect(isSettleUndoKey(key({ metaKey: true }, outside))).toBe(true);
  // An emptied field still has its deleted text to undo.
  expect(isSettleUndoKey(key({ metaKey: true }, inField))).toBe(false);
});
