// All chats status filter (cx-htpk0, Claude desktop parity): the header's Filter menu narrows the
// list to the chats that are working, the ones that wait on the user, or the finished ones, which
// are the indexed chats plus live chats at rest. All is the default and shows what the list showed.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// TanStack Virtual sizes the list from layout, which JSDOM lacks: give every element a viewport.
dom.window.HTMLElement.prototype.getBoundingClientRect = () =>
  ({ top: 0, left: 0, right: 600, bottom: 800, width: 600, height: 800, x: 0, y: 0, toJSON() {} }) as DOMRect;
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const document = dom.window.document;
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const titles = () => [...document.querySelectorAll(".nt-all-title")].map((title) => title.textContent);
const filter = () => document.querySelector<HTMLButtonElement>('.nt-chats-head button[aria-label="Filter"]');
const pick = async (label: string) => {
  await act(async () => filter()!.click());
  await settle();
  const item = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (entry) => entry.textContent?.trim() === label,
  );
  expect(item).toBeDefined();
  await act(async () => item!.click());
  await settle();
  // A pick closes the menu, as a macOS pop-up does.
  expect(filter()!.getAttribute("aria-expanded")).not.toBe("true");
  expect(document.querySelector('[role="menuitemradio"]')).toBeNull();
};

const active = [
  { id: "s-run", title: "Running chat", harness: "claude", state: "running" as const, label: "Working" },
  { id: "s-ask", title: "Asking chat", harness: "codex", state: "input" as const, label: "Needs input" },
  { id: "s-fail", title: "Failed chat", harness: "claude", state: "failed" as const, label: "Failed" },
  { id: "s-new", title: "Unread chat", harness: "claude", state: "unread" as const, label: "Unread" },
];
const load = async () => ({
  chats: [{ key: "old", harness: "claude", title: "Indexed chat", cwd: "/tmp/cmux", updatedAt: 1 }],
  ready: true,
});

test("the Filter menu narrows All chats to working, waiting or finished chats", async () => {
  const root = createRoot(document.getElementById("root")!);
  await act(async () => root.render(<AllChatsList load={load} onOpen={() => {}} active={active} now={10} />));
  await settle();
  // All, the default, shows every live chat and the indexed one, as before.
  expect(filter()?.textContent).toContain("All");
  expect(titles()).toEqual(["Running chat", "Asking chat", "Failed chat", "Unread chat", "Indexed chat"]);

  await pick("Working");
  expect(titles()).toEqual(["Running chat"]);

  // A failed turn waits on the user as much as a question does.
  await pick("Needs input");
  expect(titles()).toEqual(["Asking chat", "Failed chat"]);

  // Finished: live chats at rest, then every indexed chat.
  await pick("Done");
  expect(titles()).toEqual(["Unread chat", "Indexed chat"]);

  await pick("All");
  expect(titles()).toEqual(["Running chat", "Asking chat", "Failed chat", "Unread chat", "Indexed chat"]);
  await act(async () => root.unmount());
});

test("a filter with no matching chat says so instead of showing an empty list", async () => {
  const root = createRoot(document.getElementById("root")!);
  await act(async () => root.render(<AllChatsList load={load} onOpen={() => {}} active={[active[3]!]} now={10} />));
  await settle();
  await pick("Working");
  expect(titles()).toEqual([]);
  expect(document.querySelector(".nt-chats-empty")?.textContent).toBe("No matching chats");
  await act(async () => root.unmount());
});
