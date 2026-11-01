// Leo 2026-10-18: closing or opening a workspace re-mounts its New Tab page, which read every settled
// value again and jittered: the Chats list emptied and refilled (a `chats.page` read on each mount),
// and the machine chip flipped from "This Mac" to the machine's name after the handshake (that half is
// #22211's, new-tab-first-frame-project.test.ts). A list that mounts again draws the rows it last
// showed on its first frame and reads its first page only when the chat index pushed a change since.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  // Every agent page shares one website data store, so this origin's localStorage is the app run's.
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://pane.test/" });
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  // JSDOM lays nothing out: every element reports a tall box so the virtual list draws its rows.
  window.HTMLElement.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, top: 0, left: 0, right: 600, bottom: 800, width: 600, height: 800, toJSON() {} }) as DOMRect;
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  // The device chats and the settled list are module state every later test file in this process shares.
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  setDeviceChats([]);
  globalThis.localStorage?.clear();
  const { resetSettledChatsForTests } = await import("../src/agent-session/acpmux/newtab/settledCache");
  resetSettledChatsForTests();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (key: string, updatedAt: number) => ({ key, harness: "claude", title: key, cwd: "/tmp/cmux", updatedAt });
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

let reads = 0;
let page: { chats: ReturnType<typeof row>[]; nextCursor?: string; ready: boolean } = {
  chats: [row("cg-next-reds", 3), row("cg-lane-adopt", 2)],
  ready: true,
};
// After the first read a reply never comes: whatever the list draws then is what it already knew.
let answer = true;
const load = () => {
  reads += 1;
  return answer ? Promise.resolve(page) : new Promise<never>(() => {});
};

async function mountList() {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
}

test("a New Tab list mounted again after a workspace close and open draws its rows at once and reads nothing", async () => {
  await mountList();
  await settle();
  expect(reads).toBe(1);
  expect(host.textContent).toContain("cg-next-reds");

  // The workspace closes (the page goes) and another opens (a page mounts its list again).
  act(() => root!.unmount());
  answer = false;
  await mountList();

  expect(host.textContent).toContain("cg-next-reds");
  expect(host.textContent).toContain("cg-lane-adopt");
  expect(reads).toBe(1);
});

test("a chat that changed while no list was mounted is read once by the next list, over the rows it shows", async () => {
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  act(() => root!.unmount());
  setDeviceChats([{ key: "cg-steward-old", harness: "claude", updatedAt: 4 }]);
  answer = true;
  page = { chats: [row("cg-steward-old", 4), row("cg-next-reds", 3), row("cg-lane-adopt", 2)], ready: true };
  await mountList();

  // The rows it knew draw first; the changed page lands on top of them.
  expect(host.textContent).toContain("cg-next-reds");
  await settle();
  expect(reads).toBe(2);
  expect(host.textContent).toContain("cg-steward-old");
});

test("a new page draws the rows another page read, then reads its own first page once", async () => {
  // Another page read them; this page has read nothing and heard no push (its context's warm
  // device chats are not a push it read), so what it draws may be stale.
  const { resetSettledChatsForTests } = await import("../src/agent-session/acpmux/newtab/settledCache");
  act(() => root!.unmount());
  resetSettledChatsForTests({ keepStore: true });
  const before = reads;
  page = { chats: [row("cg-fresh", 5), row("cg-steward-old", 4)], ready: true };
  await mountList();
  expect(host.textContent).toContain("cg-steward-old");
  await settle();
  expect(reads).toBe(before + 1);
  expect(host.textContent).toContain("cg-fresh");
});

test("a chat deleted since another page read the list is gone after the new page's first read", async () => {
  // The saved rows name a chat archived or deleted since: the first read replaces them, so the
  // list never offers a chat that no longer opens (#22115 review).
  const { resetSettledChatsForTests } = await import("../src/agent-session/acpmux/newtab/settledCache");
  act(() => root!.unmount());
  resetSettledChatsForTests({ keepStore: true });
  page = { chats: [row("cg-fresh", 5)], ready: true };
  await mountList();
  await settle();
  expect(host.textContent).toContain("cg-fresh");
  expect(host.textContent).not.toContain("cg-steward-old");
});

test("a list mounted again with nothing changed since keeps its rows when a later push reads the first page", async () => {
  // Only a first read over saved rows replaces them: a mount that read nothing leaves the list as
  // any loaded list, whose later pages stay when a push reads the first page again (#22793 review).
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  act(() => root!.unmount());
  const before = reads;
  await mountList();
  await settle();
  expect(reads).toBe(before);
  // The first page still has a cursor: a row it does not name may be on a later page, so it stays.
  // A first page with no cursor is the whole list and drops what it omits (AllChatsList.test.tsx).
  page = { chats: [row("cg-newer", 6)], nextCursor: "older", ready: true };
  act(() => setDeviceChats([{ key: "cg-newer", harness: "claude", updatedAt: 6 }]));
  await settle();
  expect(reads).toBe(before + 1);
  expect(host.textContent).toContain("cg-newer");
  expect(host.textContent).toContain("cg-fresh");
});
