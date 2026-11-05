// One chat open as a tab in two workspaces at once (Leo, 2026-11-03: "i feel like right split is fine
// on click by default (extra view doesn't really affect anything), and you can riht click to go to it.
// but of course we just have to be prepared to mitigate oddities"): each tab keeps its own Session
// Info, so one tab's reload never takes the other tab's open state, width or folds. A tab with no state
// of its own reads the chat's (a chat saved before keys were per tab). Each page is its own store over
// one storage, as each tab is its own page.
import { expect, test } from "bun:test";
import {
  createSessionInfoStore,
  SESSION_INFO_INDEX_KEY,
  SESSION_INFO_PANE_PREFIX,
  tabEntry,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";

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

/// Tab `tab`'s page showing `chat`, as the app builds it: the handshake names the tab, then the chat binds.
function page(storage: Storage, tab: string, chat = "chat-1") {
  const store = createSessionInfoStore(() => storage);
  store.setTab(tab);
  store.bind(chat);
  return store;
}

test("two tabs of one chat keep their own Session Info across a reload", () => {
  const storage = memoryStorage();
  const left = page(storage, "tab-A");
  const right = page(storage, "tab-B");
  left.setOpen(true);
  left.setWidth(400);
  right.setOpen(false);
  right.setSection("usage", true);

  // Tab A's page reloads (a web update): it shows its own state, not tab B's, which was saved last.
  const leftAgain = page(storage, "tab-A");
  expect(leftAgain.current().open).toBe(true);
  expect(leftAgain.current().width).toBe(400);
  expect(leftAgain.current().sections.usage).toBe(false);
  // Its first frame, read before the bind, is its own too.
  const leftFirstFrame = createSessionInfoStore(() => storage);
  leftFirstFrame.setTab("tab-A");
  expect(leftFirstFrame.shownFor("chat-1").open).toBe(true);

  const rightAgain = page(storage, "tab-B");
  expect(rightAgain.current().open).toBe(false);
  expect(rightAgain.current().sections.usage).toBe(true);
});

test("a tab with no state of its own reads the chat's old entry, then keeps its own", () => {
  const storage = memoryStorage();
  // Saved before keys were per tab: the chat's entry only.
  const before = createSessionInfoStore(() => storage);
  before.bind("chat-1");
  before.setOpen(false);
  before.setWidth(480);
  expect(storage.getItem(SESSION_INFO_PANE_PREFIX + tabEntry("chat-1", "tab-A"))).toBeNull();

  const tab = page(storage, "tab-A");
  expect(tab.current().open).toBe(false);
  expect(tab.current().width).toBe(480);

  // Its own choice is its own from here; the chat's entry follows the latest choice in any tab.
  tab.setOpen(true);
  expect(storage.getItem(SESSION_INFO_PANE_PREFIX + tabEntry("chat-1", "tab-A"))).not.toBeNull();
  const other = page(storage, "tab-B");
  expect(other.current().open).toBe(true);
  other.setOpen(false);
  expect(page(storage, "tab-A").current().open).toBe(true);
  // Both entries are in the index, so pruning reaches the tab's too.
  const index = JSON.parse(storage.getItem(SESSION_INFO_INDEX_KEY) ?? "[]") as [string, number][];
  expect(index.map(([id]) => id)).toEqual(
    expect.arrayContaining([tabEntry("chat-1", "tab-A"), tabEntry("chat-1", "tab-B"), "chat-1"]),
  );
});

test("a page a tab adopts after it bound (a prewarmed spare) reads that tab's state", () => {
  const storage = memoryStorage();
  const tab = page(storage, "tab-A");
  tab.setOpen(false);
  page(storage, "tab-B").setOpen(true);

  // The spare bound the chat before the host named its tab: it shows the chat's latest (tab B's).
  const spare = createSessionInfoStore(() => storage);
  spare.bind("chat-1");
  expect(spare.current().open).toBe(true);
  let heard = 0;
  spare.subscribe(() => heard++);
  spare.setTab("tab-A");
  expect(spare.current().open).toBe(false);
  expect(heard).toBeGreaterThan(0);
});
