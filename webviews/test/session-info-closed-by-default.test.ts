// Session Info is closed by default, and opening it is one pane's choice only (Leo, 2026-11-07: "don't
// have it constantly opened by default ... if you have it on your main agent pane, you don't
// necessarily want it to auto open on the next one or whatever"). A new chat, a new agent pane, or a
// new tab on a chat starts with it closed whatever another pane chose; a pane's own choice comes back
// for that pane (a relaunch, a reload). Each pane is its own store over one storage, as each pane is
// its own page over one origin's localStorage.
import { expect, test } from "bun:test";
import { createSessionInfoStore } from "../src/agent-session/acpmux/session-info/sessionInfoState";

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    key: (index: number) => [...map.keys()][index] ?? null,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, String(value)),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

/// A pane's page as the app builds it: the handshake names its tab, then its chat binds.
function pane(storage: Storage, chat: string | undefined, tab?: string) {
  const store = createSessionInfoStore(() => storage);
  if (tab) store.setTab(tab);
  store.bind(chat);
  return store;
}

test("a first chat in a first pane starts with Session Info closed", () => {
  const storage = memoryStorage();
  expect(pane(storage, "chat-1", "tab-main").current().open).toBe(false);
  // No storage at all (a private window) too.
  const bare = createSessionInfoStore(() => undefined);
  bare.bind("chat-1");
  expect(bare.current().open).toBe(false);
});

test("a new agent pane starts closed after the main pane opened Session Info", () => {
  const storage = memoryStorage();
  const main = pane(storage, "chat-main", "tab-main");
  main.setOpen(true);
  main.setWidth(440);

  // A new pane with a new chat: closed from its first frame (read before the bind) and after it; it
  // takes the last width, not the open.
  const next = createSessionInfoStore(() => storage);
  next.setTab("tab-next");
  expect(next.shownFor("chat-next").open).toBe(false);
  next.bind("chat-next");
  expect(next.current()).toMatchObject({ open: false, width: 440 });

  // A new pane whose chat has no session yet (a new chat before its first prompt) too.
  const unsent = pane(storage, undefined, "tab-unsent");
  expect(unsent.current().open).toBe(false);
  unsent.bind("chat-unsent");
  expect(unsent.current().open).toBe(false);

  // A new tab opened on the main pane's own chat: the main tab's open is the main tab's.
  expect(pane(storage, "chat-main", "tab-other").current().open).toBe(false);

  // An install that saved the old shared open choice opens nothing either.
  storage.setItem("cmux.agentPane.inspector.open", "1");
  expect(pane(storage, "chat-later", "tab-later").current().open).toBe(false);
});

test("the same pane moving to a new chat starts it closed", () => {
  const storage = memoryStorage();
  const main = pane(storage, "chat-1", "tab-main");
  main.setOpen(true);

  // New chat in the pane, no session yet: closed from its first frame.
  expect(main.shownFor(undefined).open).toBe(false);
  main.bind(undefined);
  expect(main.current().open).toBe(false);
  // Its session arrives: still closed, and saved closed for it.
  main.bind("chat-2");
  expect(main.current().open).toBe(false);
  // A chat with a session the pane never showed: closed from its first frame.
  expect(main.shownFor("chat-3").open).toBe(false);
  // Back to the first chat: its own open.
  main.bind("chat-1");
  expect(main.current().open).toBe(true);
});

test("a pane's own open choice survives for that pane", () => {
  const storage = memoryStorage();
  const main = pane(storage, "chat-main", "tab-main");
  main.setOpen(true);
  pane(storage, "chat-side", "tab-side");

  // A reload or relaunch of the main pane shows it open again, from its first frame.
  const reloaded = createSessionInfoStore(() => storage);
  reloaded.setTab("tab-main");
  expect(reloaded.shownFor("chat-main").open).toBe(true);
  reloaded.bind("chat-main");
  expect(reloaded.current().open).toBe(true);

  // The other pane is still closed after its own reload, and its open never reaches the main pane.
  const side = pane(storage, "chat-side", "tab-side");
  expect(side.current().open).toBe(false);
  side.setOpen(true);
  main.setOpen(false);
  expect(pane(storage, "chat-side", "tab-side").current().open).toBe(true);
  expect(pane(storage, "chat-main", "tab-main").current().open).toBe(false);

  // A pane with no tab (an older host) keeps its choice by chat.
  const untabbed = pane(storage, "chat-untabbed");
  untabbed.setOpen(true);
  expect(pane(storage, "chat-untabbed").current().open).toBe(true);
});

test("opening it in a new chat before its first prompt is that chat's choice", () => {
  const storage = memoryStorage();
  const fresh = pane(storage, undefined, "tab-new");
  fresh.setOpen(true);
  fresh.bind("chat-new");
  expect(fresh.current().open).toBe(true);
  expect(pane(storage, "chat-new", "tab-new").current().open).toBe(true);
  // And still no other new pane's.
  expect(pane(storage, "chat-other", "tab-other").current().open).toBe(false);
});
