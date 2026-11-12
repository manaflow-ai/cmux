// The History page's list can come before the owner has listed everything (`pending_kinds`,
// cmux#41639). The page must not take that short list for the whole list and stop: it asks again by
// itself, on one timer that backs off (1 s, 2 s, 4 s, then each 8 s), until a reply is complete.
import { afterEach, expect, jest, test } from "bun:test";
import { MockHistoryProvider } from "../src/pages/history/mockProvider";
import { HistoryStore } from "../src/pages/history/store";
import { HistoryOps, type HistoryEntry } from "../src/pages/history/types";

const lists = (provider: MockHistoryProvider) => provider.calls.filter((call) => call.op === HistoryOps.list).length;

/** Lets the store's promise chains run to their end (a reply, then its `set`); no timer moves. */
async function settle(): Promise<void> {
  for (let turn = 0; turn < 60; turn += 1) await Promise.resolve();
}

async function pendingStore() {
  jest.useFakeTimers();
  const provider = new MockHistoryProvider();
  provider.pendingKinds = ["agent"];
  const store = new HistoryStore(provider, { newKey: () => "k" });
  const leave = store.subscribe(() => {});
  await settle();
  return { provider, store, leave };
}

const scope = globalThis as Record<string, unknown>;
const savedDocument = scope.document;

afterEach(() => {
  jest.useRealTimers();
  if (savedDocument === undefined) delete scope.document;
  else scope.document = savedDocument;
});

test("a list that is not complete is read again after 1, 2, 4, then each 8 s, until it is complete", async () => {
  const { provider, store, leave } = await pendingStore();
  expect(lists(provider)).toBe(1);
  expect(store.getSnapshot().pending).toBe(true);
  expect(store.getSnapshot().entries.length).toBeGreaterThan(0);
  for (const wait of [1000, 2000, 4000, 8000, 8000]) {
    const before = lists(provider);
    jest.advanceTimersByTime(wait - 1);
    await settle();
    expect(lists(provider)).toBe(before);
    jest.advanceTimersByTime(1);
    await settle();
    expect(lists(provider)).toBe(before + 1);
    expect(store.getSnapshot().pending).toBe(true);
  }
  provider.pendingKinds = [];
  jest.advanceTimersByTime(8000);
  await settle();
  expect(store.getSnapshot().pending).toBe(false);
  const complete = lists(provider);
  jest.advanceTimersByTime(60_000);
  await settle();
  expect(lists(provider)).toBe(complete);
  leave();
});

test("history-changed makes the next read sooner; it adds no timer and does not start the waits again", async () => {
  const { provider, leave } = await pendingStore();
  const entry: HistoryEntry = { id: "page:local:new", kind: "page", at_ms: Date.now(), title: "new", available: true };
  provider.push(entry);
  await settle();
  expect(lists(provider)).toBe(2);
  // The one timer of the first reply still runs to its 1 s...
  jest.advanceTimersByTime(1000);
  await settle();
  expect(lists(provider)).toBe(3);
  // ...and the wait after it is 2 s: a second timer, or waits that start again, would read at 1 s.
  jest.advanceTimersByTime(1000);
  await settle();
  expect(lists(provider)).toBe(3);
  jest.advanceTimersByTime(1000);
  await settle();
  expect(lists(provider)).toBe(4);
  leave();
});

test("the page stops asking when the person leaves it, and when the owner goes away", async () => {
  const left = await pendingStore();
  left.leave();
  jest.advanceTimersByTime(60_000);
  await settle();
  expect(lists(left.provider)).toBe(1);

  const down = await pendingStore();
  down.provider.offline = true;
  down.provider.page.setConnected(false);
  await settle();
  jest.advanceTimersByTime(60_000);
  await settle();
  expect(lists(down.provider)).toBe(1);
  expect(down.store.getSnapshot().pending).toBe(false);
  down.leave();
});

test("a re-read that fails does not end the reads: the list is still not complete", async () => {
  const { provider, store, leave } = await pendingStore();
  const call = provider.call.bind(provider);
  let fail = true;
  provider.call = (async (op: string, params: unknown) => {
    if (op === HistoryOps.list && fail) {
      provider.calls.push({ op, params });
      throw new Error("history is busy");
    }
    return call(op, params);
  }) as typeof provider.call;
  jest.advanceTimersByTime(1000);
  await settle();
  expect(lists(provider)).toBe(2);
  expect(store.getSnapshot().error).toBe("history is busy");
  expect(store.getSnapshot().pending).toBe(true);
  fail = false;
  jest.advanceTimersByTime(2000);
  await settle();
  expect(lists(provider)).toBe(3);
  expect(store.getSnapshot().error).toBeUndefined();
  leave();
});

test("a hidden page does not read on the timer; it reads when it shows again", async () => {
  let shown: (() => void) | undefined;
  const page = {
    visibilityState: "hidden",
    addEventListener: (type: string, listener: () => void) => {
      if (type === "visibilitychange") shown = listener;
    },
    removeEventListener: (type: string, listener: () => void) => {
      if (type === "visibilitychange" && shown === listener) shown = undefined;
    },
  };
  scope.document = page;
  const { provider, leave } = await pendingStore();
  jest.advanceTimersByTime(60_000);
  await settle();
  expect(lists(provider)).toBe(1);
  expect(shown).toBeDefined();
  page.visibilityState = "visible";
  shown?.();
  await settle();
  expect(lists(provider)).toBe(2);
  leave();
  expect(shown).toBeUndefined();
});
