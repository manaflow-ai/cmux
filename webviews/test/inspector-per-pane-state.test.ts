// Session Info (the Inspector, inspector/inspectorState.ts) is each chat pane's own (Leo,
// 2026-10-25: "basically the video shows the session rail opening and closing it opens and closes on
// the other side too when you do one... they should all be individual per pane"). Every chat pane is
// its own page on one origin, so they share localStorage. Here a pane is its own copy of the module
// (imported under its own query, as each page loads its own), all over one jsdom localStorage; a
// pane after a relaunch is a fresh copy over the same storage.
import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";

type Module = typeof import("../src/agent-session/acpmux/inspector/inspectorState");
const MODULE = new URL("../src/agent-session/acpmux/inspector/inspectorState.ts", import.meta.url).pathname;
let loads = 0;
/// A chat pane's page showing chat `sessionId`: its own copy of the module.
async function page(sessionId: string): Promise<Module> {
  const module = (await import(`${MODULE}?pane=${++loads}`)) as Module;
  // Pages before 2026-10-25 had no chat to bind: they all shared one state.
  (module as Partial<Module>).bindInspectorPane?.(sessionId);
  return module;
}
const PREFIX = "cmux.agentPane.inspector.pane.";

let dom: JSDOM;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  const replacements: Record<string, unknown> = {
    localStorage: dom.window.localStorage,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
});
afterEach(() => {
  setSystemTime();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom.window.close();
});

/// What another page sees of a write: a storage event on its window (jsdom fires none for its own).
const storageEvent = (key: string) => dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key }));

test("a toggle, a drag or a fold in one pane leaves the other pane as it was", async () => {
  const left = await page("chat-left");
  const right = await page("chat-right");
  expect(left.inspectorState().open).toBe(true);
  expect(right.inspectorState().open).toBe(true);

  left.setInspectorOpen(false);
  left.setInspectorWidth(480);
  left.setInspectorSection("context", true);
  for (const key of Object.keys(localStorage)) storageEvent(key);

  expect(left.inspectorState()).toMatchObject({ open: false, width: 480, sections: { context: true } });
  expect(right.inspectorState()).toMatchObject({ open: true, width: 320, sections: { context: false } });
});

test("after a relaunch each pane shows its own state again", async () => {
  const left = await page("chat-left");
  const right = await page("chat-right");
  left.setInspectorOpen(false);
  right.setInspectorOpen(true);
  right.setInspectorWidth(400);

  expect((await page("chat-left")).inspectorState().open).toBe(false);
  expect((await page("chat-right")).inspectorState()).toMatchObject({ open: true, width: 400 });
});

test("Sources View all persists with the pane's chat", async () => {
  const left = await page("chat-left");
  left.setInspectorSourcesAll(true);
  const relaunched = await page("chat-left");
  expect(relaunched.inspectorState().sourcesAll).toBe(true);
  const other = await page("chat-right");
  expect(other.inspectorState().sourcesAll).toBe(false);
});

test("a pane with no state of its own starts from the last choice, and the old shared key migrates", async () => {
  // The single key every pane shared before: an old install's closed Inspector stays closed.
  localStorage.setItem("cmux.agentPane.inspector.open", "0");
  localStorage.setItem("cmux.agentPane.inspector.width", "420");
  expect((await page("chat-old")).inspectorState()).toMatchObject({ open: false, width: 420 });

  (await page("chat-a")).setInspectorOpen(true);
  expect((await page("chat-new")).inspectorState().open).toBe(true);
});

test("the same chat in two panes: a toggle in one does not move the other", async () => {
  const one = await page("chat-same");
  const two = await page("chat-same");
  one.setInspectorOpen(false);
  for (const key of Object.keys(localStorage)) storageEvent(key);
  expect(two.inspectorState().open).toBe(true);
});

/// Storage as a page that read it now sees it: its reads are that moment's,
/// its writes land in the real storage.
function staleView(real: Storage): Storage {
  const seen = new Map<string, string>();
  for (let index = 0; index < real.length; index++) {
    const key = real.key(index)!;
    seen.set(key, real.getItem(key)!);
  }
  return {
    get length() {
      return seen.size;
    },
    key: (index: number) => [...seen.keys()][index] ?? null,
    getItem: (key: string) => seen.get(key) ?? null,
    setItem: (key: string, value: string) => {
      seen.set(key, value);
      real.setItem(key, value);
    },
    removeItem: (key: string) => {
      seen.delete(key);
      real.removeItem(key);
    },
    clear: () => real.clear(),
  };
}

test("two panes saving at once keep both chats' changes", async () => {
  const { createInspectorStore } = await page("unbound");
  const a = createInspectorStore(() => localStorage);
  a.bind("chat-a");
  // Pane B read the storage before pane A's save landed, and saves after it.
  const view = staleView(localStorage);
  const b = createInspectorStore(() => view);
  b.bind("chat-b");
  a.setOpen(false);
  b.setWidth(500);

  const fresh = (sessionId: string) => {
    const store = createInspectorStore(() => localStorage);
    store.bind(sessionId);
    return store.current();
  };
  expect(fresh("chat-a").open).toBe(false);
  expect(fresh("chat-b").width).toBe(500);
});

test("with no session the pane saves nothing until one comes, then saves under it", async () => {
  const { createInspectorStore } = await page("unbound");
  const store = createInspectorStore(() => localStorage);
  store.bind("chat-a");
  // A harness switch shows a new chat with no session yet: the last chat is no longer the pane's.
  store.bind(undefined);
  store.setOpen(false);
  const relaunched = createInspectorStore(() => localStorage);
  relaunched.bind("chat-a");
  expect(relaunched.current().open).toBe(true);
  // The new chat's session arrives: what the pane shows is saved as that chat's.
  store.bind("chat-new");
  const again = createInspectorStore(() => localStorage);
  again.bind("chat-new");
  expect(again.current().open).toBe(false);
});

test("storage keeps the newest chats of the last 30 days, and always the pane's own", async () => {
  const { createInspectorStore, PANES_KEPT } = await page("unbound");
  const pane = (sessionId: string) => {
    const store = createInspectorStore(() => localStorage);
    store.bind(sessionId);
    return store;
  };
  setSystemTime(new Date("2026-09-01T00:00:00Z"));
  pane("chat-stale").setOpen(false);
  for (let index = 0; index < PANES_KEPT + 20; index++) {
    setSystemTime(new Date(Date.UTC(2026, 9, 25, 0, 0, index)));
    pane(`chat-${index}`).setOpen(index % 2 === 0);
  }
  const kept = () => Object.keys(localStorage).filter((key) => key.startsWith(PREFIX));
  expect(kept().length).toBe(PANES_KEPT);
  expect(localStorage.getItem(`${PREFIX}chat-stale`)).toBeNull();
  expect(localStorage.getItem(`${PREFIX}chat-0`)).toBeNull();
  expect(localStorage.getItem(`${PREFIX}chat-${PANES_KEPT + 19}`)).not.toBeNull();

  // The clock set back a day: the pane's chat is older than every kept one, and still kept.
  setSystemTime(new Date("2026-10-24T00:00:00Z"));
  const own = pane("chat-now");
  own.setOpen(false);
  expect(kept().length).toBe(PANES_KEPT);
  expect(localStorage.getItem(`${PREFIX}chat-now`)).not.toBeNull();
  expect(pane("chat-now").current().open).toBe(false);
});

/// `real` counting its reads.
function countingView(real: Storage) {
  const counts = { getItem: 0, key: 0, length: 0 };
  const view: Storage = {
    get length() {
      counts.length++;
      return real.length;
    },
    key: (index: number) => {
      counts.key++;
      return real.key(index);
    },
    getItem: (key: string) => {
      counts.getItem++;
      return real.getItem(key);
    },
    setItem: (key: string, value: string) => real.setItem(key, value),
    removeItem: (key: string) => real.removeItem(key),
    clear: () => real.clear(),
  };
  return { view, counts };
}

test("a toggle reads a bounded number of keys, however full the storage is", async () => {
  const { createInspectorStore, PANES_KEPT } = await page("unbound");
  for (let index = 0; index < 1000; index++) localStorage.setItem(`other.app.key.${index}`, String(index));
  for (let index = 0; index < PANES_KEPT; index++) {
    const store = createInspectorStore(() => localStorage);
    store.bind(`chat-${index}`);
  }
  const { view, counts } = countingView(localStorage);
  const store = createInspectorStore(() => view);
  store.bind("chat-0");
  // The page's one sweep (its first save) has run; every toggle after it reads only the chat's
  // state and the small index.
  store.setOpen(false);
  counts.getItem = counts.key = counts.length = 0;
  for (let toggle = 0; toggle < 10; toggle++) store.setOpen(toggle % 2 === 0);
  store.setSection("context", true);
  store.setWidth(400);
  expect({ key: counts.key, length: counts.length }).toEqual({ key: 0, length: 0 });
  expect(counts.getItem).toBeLessThanOrEqual(12 * 2);
  expect(Object.keys(localStorage).filter((key) => key.startsWith(PREFIX)).length).toBe(PANES_KEPT);
});

test("a chat's key that no index lists is still pruned", async () => {
  const { createInspectorStore, PANES_KEPT } = await page("unbound");
  // Another pane's index write lost this chat (its key is there, the index does not list it).
  localStorage.setItem(`${PREFIX}chat-lost`, JSON.stringify({ open: false, at: Date.UTC(2026, 7, 1) }));
  setSystemTime(new Date("2026-10-25T00:00:00Z"));
  const store = createInspectorStore(() => localStorage);
  store.bind("chat-a");
  expect(localStorage.getItem(`${PREFIX}chat-lost`)).toBeNull();
  expect(PANES_KEPT).toBe(200);
});

for (const [name, savedByB] of [
  ["later", "2026-10-25T00:00:00Z"],
  ["earlier, the clock set back", "2026-08-01T00:00:00Z"],
] as const)
  test(`pruning from a stale index never drops a chat another pane saved since (${name})`, async () => {
    const { createInspectorStore, INSPECTOR_INDEX_KEY } = await page("");
    const pane = (sessionId: string, storage: () => Storage = () => localStorage) => {
      const store = createInspectorStore(storage);
      store.bind(sessionId);
      return store;
    };
    // Chat X, saved more than 30 days ago: due for pruning.
    setSystemTime(new Date("2026-09-01T00:00:00Z"));
    pane("chat-x");
    // Pane A reads the index now: it lists X at that old time.
    const staleIndex = localStorage.getItem(INSPECTOR_INDEX_KEY);
    expect(staleIndex).toContain('"chat-x"');
    const view: Storage = {
      get length() {
        return localStorage.length;
      },
      key: (index: number) => localStorage.key(index),
      getItem: (key: string) => (key === INSPECTOR_INDEX_KEY ? staleIndex : localStorage.getItem(key)),
      setItem: (key: string, value: string) => localStorage.setItem(key, value),
      removeItem: (key: string) => localStorage.removeItem(key),
      clear: () => localStorage.clear(),
    };
    // Pane B saves X, closed, before pane A's save lands; its clock may be behind the index's time.
    setSystemTime(new Date(savedByB));
    pane("chat-x").setOpen(false);
    // Pane A saves, pruning from the index it read before B's save.
    setSystemTime(new Date("2026-10-25T00:00:01Z"));
    pane("chat-a", () => view).setOpen(true);

    expect(localStorage.getItem(`${PREFIX}chat-x`)).not.toBeNull();
    expect(pane("chat-x").current().open).toBe(false);
    // X is listed again, so a later save still prunes it in turn.
    expect(localStorage.getItem(INSPECTOR_INDEX_KEY)).toContain('"chat-x"');
  });
