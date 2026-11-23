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
  // Half of the first wait (1 s) is gone when the event comes.
  jest.advanceTimersByTime(500);
  await settle();
  expect(lists(provider)).toBe(1);
  provider.push(entry);
  await settle();
  expect(lists(provider)).toBe(2);
  // The one timer of the first reply still runs to its 1 s: a timer that the event started again would read 500 ms later.
  jest.advanceTimersByTime(500);
  await settle();
  expect(lists(provider)).toBe(3);
  // The wait after it is 2 s, not 1 s: the event did not start the waits again, and there is no second timer.
  jest.advanceTimersByTime(1000);
  await settle();
  expect(lists(provider)).toBe(3);
  // An event in that 2 s wait reads at once and moves neither the wait's end nor its length.
  provider.push({ ...entry, id: "page:local:newer" });
  await settle();
  expect(lists(provider)).toBe(4);
  jest.advanceTimersByTime(999);
  await settle();
  expect(lists(provider)).toBe(4);
  jest.advanceTimersByTime(1);
  await settle();
  expect(lists(provider)).toBe(5);
  // The next wait is 4 s.
  jest.advanceTimersByTime(3999);
  await settle();
  expect(lists(provider)).toBe(5);
  jest.advanceTimersByTime(1);
  await settle();
  expect(lists(provider)).toBe(6);
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
  expect(store.getSnapshot().error).toBe("Something went wrong. Try again.");
  expect(store.getSnapshot().pending).toBe(true);
  fail = false;
  jest.advanceTimersByTime(2000);
  await settle();
  expect(lists(provider)).toBe(3);
  expect(store.getSnapshot().error).toBeUndefined();
  leave();
});

/** A document that the test hides and shows; `shown` is the page's `visibilitychange` listener while it has one. */
function hiddenDocument() {
  const page = {
    visibilityState: "hidden",
    shown: undefined as (() => void) | undefined,
    addEventListener: (type: string, listener: () => void) => {
      if (type === "visibilitychange") page.shown = listener;
    },
    removeEventListener: (type: string, listener: () => void) => {
      if (type === "visibilitychange" && page.shown === listener) page.shown = undefined;
    },
  };
  scope.document = page;
  return page;
}

test("a hidden page does not read on the timer; it reads when it shows again", async () => {
  const page = hiddenDocument();
  const { provider, leave } = await pendingStore();
  jest.advanceTimersByTime(60_000);
  await settle();
  expect(lists(provider)).toBe(1);
  expect(page.shown).toBeDefined();
  page.visibilityState = "visible";
  page.shown?.();
  await settle();
  expect(lists(provider)).toBe(2);
  // The page that shows again waits on its timer again, with no listener left.
  expect(page.shown).toBeUndefined();
  leave();
});

test("a page that the person leaves while it is hidden keeps no listener and reads no more", async () => {
  const page = hiddenDocument();
  const { provider, leave } = await pendingStore();
  jest.advanceTimersByTime(1000);
  await settle();
  expect(page.shown).toBeDefined();
  leave();
  expect(page.shown).toBeUndefined();
  page.visibilityState = "visible";
  jest.advanceTimersByTime(60_000);
  await settle();
  expect(lists(provider)).toBe(1);
});
