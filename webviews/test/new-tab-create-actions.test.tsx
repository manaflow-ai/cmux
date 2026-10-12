// The New Tab page offers the three create actions (cx-ag5.7, dogfood call K2): New terminal,
// New browser tab and New chat under the field, each one click. Before, the screen had only the
// field: a blank terminal or browser tab took a shortcut, and a chat took a prompt.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

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

test("New Tab's create actions open a terminal, a browser tab and a chat", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  let left = 0;
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
  const actions = newTabScreenActions({
    callNative: async (method, params) => void calls.push({ method, params }),
    cwd: "/Users/you/src/app",
    chatCwd: "/Users/you/src/app",
    leave: () => left++,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const root: Root = createRoot(host);
  const click = async (kind: string) => {
    const button = host.querySelector<HTMLButtonElement>(`.nt-create [data-create="${kind}"]`);
    expect(button, `no ${kind} create action`).toBeTruthy();
    await act(async () => button!.click());
  };
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <NewTabScreen snapshot={noChat()} lastAgent="claude" cwd="/Users/you/src/app" {...actions} />
        </QueryClientProvider>,
      ),
    );
    const labels = [...host.querySelectorAll(".nt-create [data-create]")].map((button) => button.textContent?.trim());
    expect(labels).toEqual(["New terminal", "New browser tab", "New chat"]);

    await click("terminal");
    await click("browser");
    await click("chat");
    const opened = calls.filter((call) => call.method === "tab.open" || call.method === "chat.new");
    expect(opened).toEqual([
      // A terminal in the tab's folder, with nothing typed.
      { method: "tab.open", params: { kind: "terminal", text: "", run: false, cwd: "/Users/you/src/app" } },
      // A browser tab on the new tab page (`browser.newTabPage`), with nothing to load.
      { method: "tab.open", params: { kind: "browser", text: "" } },
      // The page becomes a chat with the agent Return would ask, sending nothing.
      { method: "chat.new", params: expect.objectContaining({ harness: "claude" }) },
    ]);
    expect(calls.some((call) => call.method === "chat.send")).toBe(false);
    expect(left).toBe(1);
  } finally {
    act(() => root.unmount());
  }
});
