// The New Tab widget view (Debug Settings `newTab.widgets`, Leo 2026-10-18): a Projects card
// (this Mac, then its recent projects, the one a chat starts in checked) and a Needs you card (the
// chats asking for input or that hit an error, each opened by a click and put away by its ×). Off,
// the page draws neither.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, session } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "customElements",
  "MutationObserver",
] as const;
const added: string[] = [];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const MINUTE = 60_000;
const now = Date.now();

const sessions = [
  session({ sessionId: "idle", title: "Tidy the README", indicator: "done", updatedAt: now - 2 * MINUTE }),
  session({
    sessionId: "failed",
    title: "Composer + picker polish: no Tonka toys",
    indicator: "failed",
    preview: "Hit an error",
    updatedAt: now - 1 * MINUTE,
    cwd: "/Users/you/src/cmux",
  }),
  session({ sessionId: "input", title: "Ship the release notes", indicator: "input", updatedAt: now - 9 * MINUTE }),
  session({ sessionId: "lost", title: "Index the docs", indicator: "lost", updatedAt: now - 30 * MINUTE }),
  session({ sessionId: "remote", title: "Remote build", indicator: "input", peer: "big-red", updatedAt: now }),
];
const projects = [
  { cwd: "/Users/you/src/web", label: "web" },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/Library/Application Support/cmux/agent-home/x", label: "x" },
];

test("the Needs you list: input first, then newest; a dismiss holds until the chat changes", async () => {
  const { attentionChats } = await import("../src/agent-session/acpmux/newtab/widgets");
  const chats = attentionChats(sessions, new Set(), 10);
  expect(chats.map((chat) => [chat.sessionId, chat.state])).toEqual([
    ["remote", "input"],
    ["input", "input"],
    ["failed", "failed"],
    ["lost", "error"],
  ]);
  expect(chats.find((chat) => chat.sessionId === "failed")?.detail).toBe("Hit an error");
  const dismissed = new Set([chats[1]!.key]);
  expect(attentionChats(sessions, dismissed, 10).map((chat) => chat.sessionId)).not.toContain("input");
  const changed = sessions.map((entry) => (entry.sessionId === "input" ? { ...entry, updatedAt: now } : entry));
  expect(attentionChats(changed, dismissed, 10).map((chat) => chat.sessionId)).toContain("input");
});

test("the Projects card lists this Mac's projects, the one used last first, never agent-home", async () => {
  const { recentProjects } = await import("../src/agent-session/acpmux/newtab/widgets");
  expect(recentProjects(projects, sessions).map((project) => project.label)).toEqual(["cmux", "web"]);
});

test("the handshake turns the widget view on only with widgets: true", async () => {
  const { newTabHost } = await import("../src/agent-session/acpmux/NewTabPage");
  expect(newTabHost({ newTab: { widgets: true } })?.widgets).toBe(true);
  expect(newTabHost({ newTab: { widgets: "yes" } })?.widgets).toBeUndefined();
  expect(newTabHost({ newTab: true })?.widgets).toBeUndefined();
});

test("New Tab draws the widget cards only when they are on; a pick, an open and a dismiss work", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { DISMISSED_STORAGE_KEY } = await import("../src/agent-session/acpmux/newtab/widgets");
  window.localStorage.removeItem(DISMISSED_STORAGE_KEY);
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
  const selected: string[] = [];
  const actions = newTabScreenActions({
    callNative: async () => undefined,
    cwd: "/Users/you",
    chatCwd: "/Users/you",
    leave: noop,
    selectSession: (id: string) => void selected.push(id),
    showAllChats: noop,
    runShell: noop,
  });
  const render = (root: Root, widgets: boolean, cwd = "/Users/you") =>
    act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <NewTabScreen
            snapshot={noChat(sessions)}
            lastAgent="claude"
            cwd={cwd}
            projects={projects}
            machineName="cosmic-gray"
            widgets={widgets}
            {...actions}
          />
        </QueryClientProvider>,
      ),
    );
  let root: Root = createRoot(host);
  try {
    await render(root, false);
    expect(host.querySelector(".nt-widgets")).toBeNull();
  } finally {
    act(() => root.unmount());
  }
  root = createRoot(host);
  try {
    await render(root, true);
    const rows = () => [...host.querySelectorAll<HTMLElement>(".nt-widget-row")];
    expect(rows().map((row) => row.textContent)).toEqual(["cosmic-gray", "cmux", "web"]);
    expect(host.querySelectorAll('.nt-widget-row[aria-pressed="true"]').length).toBe(0);
    await act(async () => rows()[2]!.click());
    expect(host.querySelector('.nt-widget-row[aria-pressed="true"]')?.textContent).toBe("web");
    expect(host.querySelector(".nt-location")?.textContent).toContain("web");

    const chats = () => [...host.querySelectorAll<HTMLElement>(".nt-widget-chat")];
    expect(chats().map((chat) => chat.querySelector(".nt-widget-title")?.textContent)).toEqual([
      "Remote build",
      "Ship the release notes",
      "Composer + picker polish: no Tonka toys",
      "Index the docs",
    ]);
    expect(chats()[2]!.querySelector(".nt-widget-state")?.textContent).toBe("Failed");
    expect(chats()[1]!.querySelector(".nt-widget-state")?.textContent).toBe("Needs input");
    await act(async () => chats()[1]!.querySelector<HTMLButtonElement>(".nt-widget-chat-open")!.click());
    expect(selected).toEqual(["input"]);
    const dismiss = chats()[2]!.querySelector<HTMLButtonElement>(".nt-widget-dismiss")!;
    expect(dismiss.getAttribute("aria-label")).toBe("Dismiss Composer + picker polish: no Tonka toys");
    await act(async () => dismiss.click());
    expect(chats().length).toBe(3);
    expect(window.localStorage.getItem(DISMISSED_STORAGE_KEY)).toContain("failed@");
  } finally {
    act(() => root.unmount());
  }
  // The dismiss holds on the next New Tab, and a dismiss there keeps the one made here (both read
  // the shared storage).
  root = createRoot(host);
  try {
    await render(root, true);
    expect(host.querySelectorAll(".nt-widget-chat").length).toBe(3);
    window.localStorage.setItem(
      DISMISSED_STORAGE_KEY,
      JSON.stringify([...JSON.parse(window.localStorage.getItem(DISMISSED_STORAGE_KEY)!), "elsewhere@1"]),
    );
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-widget-dismiss")!.click());
    const kept = JSON.parse(window.localStorage.getItem(DISMISSED_STORAGE_KEY)!) as string[];
    expect(kept.some((key) => key.startsWith("failed@"))).toBe(true);
    expect(kept).toContain("elsewhere@1");
  } finally {
    act(() => root.unmount());
  }
  // The folder the tab inherited is no pick (the chat would not start there): the card leaves it out.
  root = createRoot(host);
  try {
    await render(root, true, "/Users/you/src/cmux");
    expect([...host.querySelectorAll(".nt-widget-row")].map((row) => row.textContent)).toEqual(["cosmic-gray", "web"]);
  } finally {
    act(() => root.unmount());
    window.localStorage.removeItem(DISMISSED_STORAGE_KEY);
  }
});
