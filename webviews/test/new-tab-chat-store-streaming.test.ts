// l10n-allow-file: test fixtures.
// Leo 2026-11-04: "we're using the cpu a decent amount rn so we can once again look into what we can
// do more efficient?". Every shown agent page publishes its daemon list to the shared New Tab store
// (newtab/chatStore.ts). While agents stream, the list changes on nearly every frame (each streaming
// chat moves its `updatedAt`), and each write serialized every chat (about 3,000 on a busy Mac) and
// woke every other agent page, hidden ones too, to parse it again. A page now writes at most once per
// half second, the newest list last, and a page that hears a list it already holds skips the parse.
import { afterAll, afterEach, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "localStorage"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html>", { url: "https://pane.test/" }).window;
  Object.assign(scope, { window, document: window.document, localStorage: window.localStorage });
});

afterAll(async () => {
  window.localStorage.clear();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.reloadChatStoreForTests();
  await teardownDom(saved, { scope });
});

beforeEach(async () => {
  window.localStorage.clear();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.reloadChatStoreForTests();
});

afterEach(() => {
  jest.useRealTimers();
});

const T0 = Date.UTC(2026, 10, 4, 1, 11);
const CHATS = 3000;
const STREAMING = 40;
/// One snapshot per frame of a busy page: 20 a second for 10 seconds.
const FRAMES = 200;
const FRAME_MS = 50;

function chat(n: number, updatedAt: number): AcpmuxSessionEntry {
  return {
    sessionId: `s-${String(n).padStart(4, "0")}`,
    displayTitle: `Chat ${n}`,
    name: `Chat ${n}`,
    harness: "claude",
    status: n < STREAMING ? "running" : "ready",
    cwd: `/Users/you/src/p${n % 50}`,
    updatedAt,
    turnCount: 3,
  };
}

const connected = (sessions: AcpmuxSessionEntry[]) => ({
  connection: "session changed",
  origin: "local" as const,
  listedSessions: true as const,
  sessions,
});

/// The direct client's lists while `STREAMING` chats stream: each frame one streaming chat's entry
/// is new (its `updatedAt` moved) and every other entry is the same object.
function streamingLists(): AcpmuxSessionEntry[][] {
  let list = Array.from({ length: CHATS }, (_, index) => chat(index, T0 - index * 60_000));
  const lists: AcpmuxSessionEntry[][] = [];
  for (let frame = 0; frame < FRAMES; frame += 1) {
    const n = frame % STREAMING;
    list = list.map((entry, index) => (index === n ? chat(n, T0 + (frame + 1) * FRAME_MS) : entry));
    lists.push(list);
  }
  return lists;
}

test("a page whose chats stream writes the store at most twice a second, the newest list last", async () => {
  jest.useFakeTimers();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  // Assigning `localStorage.setItem` would store an item named "setItem": spy on the prototype.
  const proto = window.Storage.prototype;
  const setItem = proto.setItem;
  let writes = 0;
  let bytes = 0;
  proto.setItem = function (this: Storage, key: string, value: string) {
    if (key === store.CHAT_STORE_KEY_FOR_TESTS) {
      writes += 1;
      bytes += value.length;
    }
    setItem.call(this, key, value);
  };
  try {
    const lists = streamingLists();
    for (const [frame, list] of lists.entries()) {
      store.publishSessions(connected(list), T0 + (frame + 1) * FRAME_MS);
      jest.advanceTimersByTime(FRAME_MS);
    }
    jest.advanceTimersByTime(1_000);
    console.log(`chat store, ${FRAMES} frames over ${(FRAMES * FRAME_MS) / 1000} s: writes=${writes} bytes=${bytes}`);
    // Every frame changes the list: it reached the store at least once a window.
    expect(writes).toBeGreaterThanOrEqual((FRAMES * FRAME_MS) / 500 - 1);
    expect(writes).toBeLessThanOrEqual((FRAMES * FRAME_MS) / 500 + 1);
    // The store ends on the newest list.
    store.reloadChatStoreForTests();
    const newest = lists.at(-1)!;
    const head = [...newest].sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0];
    expect(store.sharedSessions([])[0]?.sessionId).toBe(head.sessionId);
    expect(store.sharedSessions([])[0]?.updatedAt).toBe(head.updatedAt);
  } finally {
    proto.setItem = setItem;
  }
});

test("a page that hides writes the list it holds at once", async () => {
  jest.useFakeTimers();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const lists = streamingLists();
  store.publishSessions(connected(lists[0]), T0 + 1);
  store.publishSessions(connected(lists[1]), T0 + 2);
  // The second list waits for the window to end; the page hides first.
  window.dispatchEvent(new window.Event("pagehide"));
  const raw = window.localStorage.getItem(store.CHAT_STORE_KEY_FOR_TESTS);
  expect(JSON.parse(raw!).at).toBe(T0 + 2);
});

test("a page that hears the list it already holds keeps it, and a changed list still updates it", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const lists = streamingLists();
  store.publishSessions(connected(lists[0]), T0 + 1);
  const before = store.sharedSessions([]);
  const same = store.encodeChatStoreForTests(lists[0], T0 + 5);
  window.dispatchEvent(new window.StorageEvent("storage", { key: store.CHAT_STORE_KEY_FOR_TESTS, newValue: same }));
  expect(store.sharedSessions([])).toBe(before);
  const changed = store.encodeChatStoreForTests(lists[1], T0 + 6);
  window.dispatchEvent(new window.StorageEvent("storage", { key: store.CHAT_STORE_KEY_FOR_TESTS, newValue: changed }));
  expect(store.sharedSessions([])[0]?.sessionId).toBe("s-0001");
  // An older write never replaces a newer one.
  const older = store.encodeChatStoreForTests(lists[0], T0 + 2);
  window.dispatchEvent(new window.StorageEvent("storage", { key: store.CHAT_STORE_KEY_FOR_TESTS, newValue: older }));
  expect(store.sharedSessions([])[0]?.sessionId).toBe("s-0001");
});

test("a held-back list never replaces a newer list another page wrote in its window", async () => {
  jest.useFakeTimers();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const lists = streamingLists();
  store.publishSessions(connected(lists[0]), T0 + 1_000);
  // This page's next list waits for the window to end.
  store.publishSessions(connected(lists[1]), T0 + 1_100);
  // Another page writes a newer, different list meanwhile.
  const newer = store.encodeChatStoreForTests(lists[5], T0 + 1_200);
  window.localStorage.setItem(store.CHAT_STORE_KEY_FOR_TESTS, newer);
  window.dispatchEvent(new window.StorageEvent("storage", { key: store.CHAT_STORE_KEY_FOR_TESTS, newValue: newer }));
  jest.advanceTimersByTime(1_000);
  expect(JSON.parse(window.localStorage.getItem(store.CHAT_STORE_KEY_FOR_TESTS)!).at).toBe(T0 + 1_200);
  expect(store.sharedSessions([])[0]?.sessionId).toBe("s-0005");
});
