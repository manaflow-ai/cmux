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

// Settings > Advanced > Experiments > Prioritize Chat Input (`experiments.chatInstantUnderLoad`): with
// the switch on, a warm store takes a changed list from the idle lane, never inside the task that
// received it; off, the list goes when its window opens, as before.
async function chatListArm(on: boolean) {
  const { setExperimentSwitches } = await import("../src/experiments/switches");
  const { pageLanes } = await import("../src/agent-session/acpmux/schedule");
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  setExperimentSwitches(on ? { chatInstantUnderLoad: true } : {});
  const head = () => store.sharedSessions([])[0]?.updatedAt;
  return { store, head, flushIdle: () => pageLanes().flush("new-tab-chat-list"), off: () => setExperimentSwitches({}) };
}

test("Prioritize Chat Input off: a changed list is written as its window opens", async () => {
  jest.useFakeTimers();
  const { store, head, flushIdle, off } = await chatListArm(false);
  try {
    store.publishSessions(connected([chat(0, T0)]), T0);
    expect(head()).toBe(T0);
    store.publishSessions(connected([chat(0, T0 + 1)]), T0 + 1);
    expect(head()).toBe(T0);
    jest.advanceTimersByTime(500);
    expect(head()).toBe(T0 + 1);
    flushIdle();
    expect(head()).toBe(T0 + 1);
  } finally {
    off();
  }
});

test("Prioritize Chat Input on: the first list goes at once, later ones from the idle lane, newest last", async () => {
  jest.useFakeTimers();
  const { store, head, flushIdle, off } = await chatListArm(true);
  try {
    // An empty store takes the first list at once, so a new tab draws it.
    store.publishSessions(connected([chat(0, T0)]), T0);
    expect(head()).toBe(T0);
    store.publishSessions(connected([chat(0, T0 + 1)]), T0 + 1);
    jest.advanceTimersByTime(500);
    // The window ended: the held list waits for the idle lane, and a newer list replaces it there.
    expect(head()).toBe(T0);
    store.publishSessions(connected([chat(0, T0 + 2)]), T0 + 2);
    expect(head()).toBe(T0);
    flushIdle();
    expect(head()).toBe(T0 + 2);
    // A page that hides still writes what it holds at once.
    jest.advanceTimersByTime(500);
    store.publishSessions(connected([chat(0, T0 + 3)]), T0 + 3);
    expect(head()).toBe(T0 + 2);
    window.dispatchEvent(new window.Event("pagehide"));
    expect(head()).toBe(T0 + 3);
  } finally {
    off();
    flushIdle();
  }
});

// The cost Prioritize Chat Input moves: the time the store takes outside the idle lane each frame
// (inside the task that received a snapshot, or its write window's timer: tasks a key or a transcript
// frame waits behind), 3,000 chats with 40 streaming, one snapshot every 50 ms for 10 s, both arms in
// one run. Prints p50, p95 and max per arm, and the idle lane's own time; the gate is that with the
// switch on no write happens outside the idle lane once the store holds a list.
test("Prioritize Chat Input: the store's cost outside the idle lane, off against on", async () => {
  jest.useFakeTimers();
  const lists = streamingLists();
  const proto = window.Storage.prototype;
  const setItem = proto.setItem;
  const measure = async (on: boolean) => {
    window.localStorage.clear();
    const { store, flushIdle, off } = await chatListArm(on);
    store.reloadChatStoreForTests();
    let inIdle = false;
    let writesOutside = 0;
    proto.setItem = function (this: Storage, key: string, value: string) {
      if (key === store.CHAT_STORE_KEY_FOR_TESTS && !inIdle) writesOutside += 1;
      setItem.call(this, key, value);
    };
    const costs: number[] = [];
    let idleMs = 0;
    try {
      for (const [frame, list] of lists.entries()) {
        const start = performance.now();
        store.publishSessions(connected(list), T0 + (frame + 1) * FRAME_MS);
        jest.advanceTimersByTime(FRAME_MS);
        costs.push(performance.now() - start);
        inIdle = true;
        const idleStart = performance.now();
        flushIdle();
        idleMs += performance.now() - idleStart;
        inIdle = false;
      }
    } finally {
      proto.setItem = setItem;
      off();
    }
    const sorted = costs.slice(1).sort((a, b) => a - b);
    const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!.toFixed(3);
    console.log(
      `chat store outside the idle lane, ${on ? "on " : "off"}: p50=${at(0.5)} ms p95=${at(0.95)} ms max=${at(1)} ms writes=${writesOutside}; idle lane total=${idleMs.toFixed(1)} ms`,
    );
    store.reloadChatStoreForTests();
    return writesOutside;
  };
  expect(await measure(false)).toBeGreaterThan(10);
  // On: only the first list (an empty store) is written outside the idle lane.
  expect(await measure(true)).toBe(1);
});

// Leo 2026-11-22: "i feel likesometimes there's like... lags every few frames or something. like a regular
// stutter". A V8 profile of his NIGHTLY's agent pages showed each 500 ms write re-encoding every chat and parsing
// the text back, 20 to 47 ms on the page's main thread each time. A write now encodes only the entries that changed
// since the last one and parses nothing.
test("a write while chats stream encodes only the changed chats and parses nothing back", async () => {
  jest.useFakeTimers();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const lists = streamingLists();
  store.publishSessions(connected(lists[0]), T0 + 1);
  jest.advanceTimersByTime(1_000);
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  let entriesEncoded = 0;
  let listsEncoded = 0;
  let parsedChars = 0;
  JSON.stringify = ((value: unknown, ...rest: unknown[]) => {
    if (value && typeof value === "object" && "sessionId" in value) entriesEncoded += 1;
    if (value && typeof value === "object" && Array.isArray((value as { sessions?: unknown }).sessions))
      listsEncoded += 1;
    return (stringify as (...args: unknown[]) => string)(value, ...rest);
  }) as typeof JSON.stringify;
  JSON.parse = ((text: string, ...rest: unknown[]) => {
    parsedChars += text.length;
    return (parse as (...args: unknown[]) => unknown)(text, ...rest);
  }) as typeof JSON.parse;
  const writes = 10;
  const started = performance.now();
  try {
    for (let frame = 1; frame <= writes; frame += 1) {
      store.publishSessions(connected(lists[frame]), T0 + 1_000 * (frame + 1));
      jest.advanceTimersByTime(1_000);
    }
  } finally {
    JSON.stringify = stringify;
    JSON.parse = parse;
  }
  const perWrite = (performance.now() - started) / writes;
  console.log(
    `chat store write at ${CHATS} chats, one changed: ${perWrite.toFixed(2)} ms, entries encoded ${entriesEncoded}`,
  );
  // One chat changed per write; a chat crossing the whole/short boundary can add one more.
  expect(entriesEncoded).toBeLessThanOrEqual(writes * 3);
  expect(listsEncoded).toBe(0);
  expect(parsedChars).toBe(0);
  // What the store holds is still the newest list, readable by another page.
  const raw = window.localStorage.getItem(store.CHAT_STORE_KEY_FOR_TESTS)!;
  expect(parse(raw).sessions.length).toBe(CHATS);
});

test("the stored text is what JSON.stringify of the kept list makes", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const lists = streamingLists();
  const sessions = lists[7];
  const text = store.encodeChatStoreForTests(sessions, T0 + 7);
  const value = JSON.parse(text) as { at: number; sessions: AcpmuxSessionEntry[] };
  expect(text).toBe(JSON.stringify(value));
  expect(value.at).toBe(T0 + 7);
  expect(value.sessions.length).toBe(CHATS);
  // The newest 60 stay whole, the rest keep their ids and folder.
  expect(value.sessions[0]?.displayTitle).toBeDefined();
  expect(value.sessions[100]?.displayTitle).toBeUndefined();
  expect(value.sessions[100]?.archived).toBe(true);
  // Encoding the same list again, from the cache, makes the same text.
  expect(store.encodeChatStoreForTests(sessions, T0 + 7)).toBe(text);
});
