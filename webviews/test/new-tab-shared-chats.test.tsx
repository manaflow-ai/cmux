// l10n-allow-file: test fixtures.
// Leo 2026-10-19 12:15: creating many chats and New Tabs fast left a torn-off window whose New Tab
// listed other chats than the main window's, and each new page drew no chats until its own daemon
// connection answered. Every agent page shares one website data store, so its localStorage is the
// app run's: one chat store every page reads and writes. Here 30 pages open fast in two windows; the
// torn-off window's pages hear the daemon once, when they connect, and never again (a hidden
// window's connection is throttled). Every page must list one identical list, the newest the
// daemon reported, in one deterministic order, with no placeholder row, and a page must draw the
// chats it is about to list on its first frame, before its own connection answers.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { url: "https://pane.test/" }).window;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(async () => {
  // The store is module state every later test file in this process shares.
  window.localStorage.clear();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.reloadChatStoreForTests();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

beforeEach(async () => {
  window.localStorage.clear();
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.reloadChatStoreForTests();
});

const T0 = Date.UTC(2026, 9, 19, 19, 15);
const PAGES = 30;

/// The chat started from the `n`th New Tab: two at a time share a millisecond (rapid creates).
function chat(n: number): AcpmuxSessionEntry {
  return {
    sessionId: `s-${String(n).padStart(2, "0")}`,
    displayTitle: `Chat ${n}`,
    name: `Chat ${n}`,
    harness: "claude",
    status: "ready",
    cwd: "/Users/you/src/cmux",
    updatedAt: T0 + Math.floor(n / 2) * 1_000,
    turnCount: 1,
  };
}

const connected = (sessions: AcpmuxSessionEntry[]) => ({
  connection: "connected",
  origin: "local" as const,
  listedSessions: true as const,
  sessions,
});

async function titles(sessions: AcpmuxSessionEntry[]): Promise<string[]> {
  const { recentChatCards } = await import("../src/agent-session/acpmux/newtab/screenModel");
  return recentChatCards(sessions, T0 + 60_000, undefined, [], 6, true).map((card) => card.title);
}

/// One page of one window: its own daemon connection's last list (empty before it answered).
type Page = { window: "main" | "torn-off"; own: AcpmuxSessionEntry[]; firstFrame: string[] };

test("30 New Tabs created fast in two windows all list one identical list, drawn on the first frame", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const daemon: AcpmuxSessionEntry[] = [];
  const pages: Page[] = [];
  for (let n = 1; n <= PAGES; n += 1) {
    // A page opens: a new JS realm that reads the store, then draws before its connection answers.
    store.reloadChatStoreForTests();
    const page: Page = { window: n % 2 ? "main" : "torn-off", own: [], firstFrame: [] };
    page.firstFrame = await titles(store.sharedSessions(page.own));
    pages.push(page);
    // Its connection answers with what the daemon has now, and a chat starts from it.
    page.own = [...daemon];
    store.publishSessions(connected(page.own), T0 + n);
    daemon.push(chat(n));
    // The main window's pages hear every change; the torn-off window's hear none after connecting.
    for (const other of pages.filter((p) => p.window === "main")) {
      other.own = [...daemon];
      store.publishSessions(connected(other.own), T0 + n);
    }
  }
  const expected = await titles(daemon);
  expect(expected).toHaveLength(6);
  const lists = await Promise.all(
    pages.map((page) => {
      store.reloadChatStoreForTests();
      return titles(store.sharedSessions(page.own));
    }),
  );
  for (const [index, list] of lists.entries())
    expect({ page: index + 1, list }).toEqual({ page: index + 1, list: expected });
  // Every page after the first drew chats on its first frame (the store), never an empty list.
  expect(
    pages
      .slice(1)
      .filter((page) => page.firstFrame.length === 0)
      .map((_, index) => index + 2),
  ).toEqual([]);
  // No placeholder row: every row is a chat's own title.
  for (const list of lists) for (const title of list) expect(title).toMatch(/^Chat \d+$/);
});

test("a list a page is showing updates in place when another page publishes", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const { createRoot } = await import("react-dom/client");
  const own: AcpmuxSessionEntry[] = [chat(1)];
  function Probe() {
    const sessions = store.useSharedSessions(own);
    return (
      <ul>
        {sessions.map((session) => (
          <li key={session.sessionId}>{session.displayTitle}</li>
        ))}
      </ul>
    );
  }
  const root: Root = createRoot(window.document.getElementById("root")!);
  await act(async () => root.render(<Probe />));
  // Another page (another realm) writes the store: this page hears it only as a storage event.
  const written = store.encodeChatStoreForTests(connected([chat(2), chat(1)]).sessions, T0 + 5);
  window.localStorage.setItem(store.CHAT_STORE_KEY_FOR_TESTS, written);
  await act(async () => {
    window.dispatchEvent(
      new window.StorageEvent("storage", { key: store.CHAT_STORE_KEY_FOR_TESTS, newValue: written }),
    );
  });
  expect([...window.document.querySelectorAll("li")].map((li) => li.textContent)).toEqual(["Chat 2", "Chat 1"]);
  await act(async () => root.unmount());
});

test("a page that is not connected never overwrites the store", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.publishSessions(connected([chat(3), chat(2)]), T0 + 1);
  store.publishSessions({ connection: "connecting", sessions: [] }, T0 + 2);
  store.publishSessions({ connection: "gallery", sessions: [chat(9)] }, T0 + 3);
  store.reloadChatStoreForTests();
  // Chats 2 and 3 started in the same second: they tie on their ids.
  expect(store.sharedSessions([]).map((session) => session.sessionId)).toEqual(["s-02", "s-03"]);
});

test("a connected page keeps publishing on later emits, whatever their reason", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  // The direct client names why it emitted, not whether it is linked: after `connected` come
  // "session changed", "attached", an event's kind.
  store.publishSessions(
    { connection: "connected", origin: "local", listedSessions: true, sessions: [chat(1)] },
    T0 + 1,
  );
  store.publishSessions(
    { connection: "session changed", origin: "local", listedSessions: true, sessions: [chat(2), chat(1)] },
    T0 + 2,
  );
  store.publishSessions(
    { connection: "permission", origin: "local", listedSessions: true, sessions: [chat(3), chat(2), chat(1)] },
    T0 + 3,
  );
  store.publishSessions({ connection: "disconnected", origin: "local", listedSessions: true, sessions: [] }, T0 + 4);
  store.publishSessions(
    { connection: "reconnecting (2)", origin: "local", listedSessions: true, sessions: [] },
    T0 + 5,
  );
  store.reloadChatStoreForTests();
  expect(store.sharedSessions([]).map((session) => session.sessionId)).toEqual(["s-02", "s-03", "s-01"]);
});

test("a chat on another machine never writes its one chat into this Mac's store", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.publishSessions(
    { connection: "connected", origin: "local", listedSessions: true, sessions: [chat(2), chat(1)] },
    T0 + 1,
  );
  store.publishSessions(
    { connection: "connected", origin: "remote", listedSessions: true, sessions: [chat(7)] },
    T0 + 2,
  );
  store.publishSessions(
    { connection: "session changed", origin: "peer", listedSessions: true, sessions: [chat(8)] },
    T0 + 3,
  );
  store.reloadChatStoreForTests();
  expect(store.sharedSessions([]).map((session) => session.sessionId)).toEqual(["s-02", "s-01"]);
});

test("a page that lists what the store holds writes nothing", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.publishSessions(connected([chat(2), chat(1)]), T0 + 1);
  const written = window.localStorage.getItem(store.CHAT_STORE_KEY_FOR_TESTS);
  // Another page's emit, new entries with the same fields.
  store.publishSessions(connected([chat(2), chat(1)]), T0 + 2);
  expect(window.localStorage.getItem(store.CHAT_STORE_KEY_FOR_TESTS)).toBe(written);
});

test("a connection's emits before it reads the daemon's list, or on an older acpmux, never write", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  store.publishSessions(connected([chat(2), chat(1)]), T0 + 1);
  // A new page's client emits "connected" (its permission rules) before its first list page.
  store.publishSessions({ connection: "connected", origin: "local", sessions: [] }, T0 + 2);
  // An acpmux that names no origin may be another machine's.
  store.publishSessions(
    { connection: "connected", origin: "unknown", listedSessions: true, sessions: [chat(9)] },
    T0 + 3,
  );
  store.reloadChatStoreForTests();
  expect(store.sharedSessions([]).map((session) => session.sessionId)).toEqual(["s-02", "s-01"]);
});

test("a chat past the newest 60 keeps its folder for the project picker", async () => {
  const store = await import("../src/agent-session/acpmux/newtab/chatStore");
  const many = Array.from({ length: 70 }, (_, index) => ({ ...chat(index + 1), cwd: `/Users/you/src/p${index + 1}` }));
  store.publishSessions(connected(many), T0 + 1);
  store.reloadChatStoreForTests();
  const oldest = store.sharedSessions([]).find((session) => session.sessionId === "s-01");
  expect(oldest?.archived).toBe(true);
  expect(oldest?.cwd).toBe("/Users/you/src/p1");
});

test("only a New Tab page of this Mac's daemon lists the shared chats, and not while its daemon is down", async () => {
  const { markMockPage, sharesChatList } = await import("../src/agent-session/acpmux/newtab/chatStore");
  // A mock App mounted by another test file in the same process marks its page; this one is not.
  markMockPage(false);
  const page = {};
  // Before the handshake a page names no origin: its context said whether it is this Mac's.
  expect(sharesChatList(page, { connection: "connecting" })).toBe(true);
  expect(sharesChatList(page, { connection: "connected", origin: "local" })).toBe(true);
  // Another machine's page (its context turns the store off), or an older acpmux that names none.
  expect(sharesChatList({ privateChatLists: true }, { connection: "connecting" })).toBe(false);
  expect(sharesChatList(page, { connection: "connected", origin: "remote" })).toBe(false);
  expect(sharesChatList(page, { connection: "connected", origin: "peer" })).toBe(false);
  expect(sharesChatList(page, { connection: "connected", origin: "unknown" })).toBe(false);
  // A daemon that is down shows that, not chats the page cannot open; a chat page lists none.
  expect(sharesChatList(page, { connection: "disconnected", origin: "local" })).toBe(false);
  expect(sharesChatList(page, { connection: "debug", origin: "local" })).toBe(false);
  expect(sharesChatList(undefined, { connection: "connected", origin: "local" })).toBe(false);
});
