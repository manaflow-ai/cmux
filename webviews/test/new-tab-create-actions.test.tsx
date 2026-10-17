// The New Tab page offers the three create actions (cx-ag5.7, dogfood call K2): New terminal,
// New browser tab and New chat under the field, each one click. Before, the screen had only the
// field: a blank terminal or browser tab took a shortcut, and a chat took a prompt.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
let root: Root | undefined;
let client: import("@tanstack/react-query").QueryClient | undefined;
let createRoot: typeof import("react-dom/client").createRoot;
let QueryClient: typeof import("@tanstack/react-query").QueryClient;
let QueryClientProvider: typeof import("@tanstack/react-query").QueryClientProvider;
let NewTabScreen: typeof import("../src/agent-session/acpmux/newtab/NewTabScreen").NewTabScreen;
let newTabScreenActions: typeof import("../src/agent-session/acpmux/newtab/screenActions").newTabScreenActions;

beforeAll(async () => {
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
    requestAnimationFrame: (run: (time: number) => void) => window.setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => window.clearTimeout(id),
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
  // Component imports belong to setup, not the first action's five-second behavior budget.
  ({ createRoot } = await import("react-dom/client"));
  ({ QueryClient, QueryClientProvider } = await import("@tanstack/react-query"));
  ({ NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen"));
  ({ newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions"));
}, 30_000);

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  client?.clear();
  client = undefined;
});

afterAll(() => {
  // Cancel jsdom timers before removing the DOM globals their callbacks use.
  window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
// JSDOM's style and Base UI effect work can exceed five seconds on a busy development host.
const interactionTimeout = 15_000;

async function mountScreen() {
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
  root = createRoot(host);
  client = new QueryClient();
  await act(async () =>
    root!.render(
      <QueryClientProvider client={client!}>
        <NewTabScreen snapshot={noChat()} lastAgent="claude" cwd="/Users/you/src/app" {...actions} />
      </QueryClientProvider>,
    ),
  );
  return { calls, left: () => left };
}

const button = (kind: string) => host.querySelector<HTMLButtonElement>(`.nt-create [data-create="${kind}"]`)!;

test.each([
  {
    kind: "terminal",
    opened: { method: "tab.open", params: { kind: "terminal", text: "", run: false, cwd: "/Users/you/src/app" } },
  },
  { kind: "browser", opened: { method: "tab.open", params: { kind: "browser", text: "" } } },
  { kind: "chat", opened: { method: "chat.new", params: expect.objectContaining({ harness: "claude" }) } },
])(
  "New Tab's $kind create action opens one item",
  async ({ kind, opened }) => {
    const { calls, left } = await mountScreen();
    expect([...host.querySelectorAll(".nt-create [data-create]")].map((item) => item.textContent?.trim())).toEqual([
      "New terminal",
      "New browser tab",
      "New chat",
    ]);
    expect(button(kind), `no ${kind} create action`).toBeTruthy();
    await act(async () => button(kind).click());
    expect(calls.filter((call) => call.method === "tab.open" || call.method === "chat.new")).toEqual([opened]);
    expect(calls.some((call) => call.method === "chat.send")).toBe(false);
    expect(left()).toBe(kind === "chat" ? 1 : 0);
  },
  interactionTimeout,
);

test(
  "New chat sends what the field holds",
  async () => {
    const { calls } = await mountScreen();
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "fix the flaky upload test");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    await act(async () => button("chat").click());
    expect(calls.filter((call) => call.method === "chat.send")).toEqual([
      { method: "chat.send", params: { text: "fix the flaky upload test" } },
    ]);
  },
  interactionTimeout,
);

test(
  "a second create click opens nothing more",
  async () => {
    const { calls } = await mountScreen();
    await act(async () => {
      button("terminal").click();
      button("terminal").click();
      button("browser").click();
    });
    expect(calls.filter((call) => call.method === "tab.open")).toEqual([
      { method: "tab.open", params: { kind: "terminal", text: "", run: false, cwd: "/Users/you/src/app" } },
    ]);
  },
  interactionTimeout,
);
