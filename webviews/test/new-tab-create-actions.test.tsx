import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";

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
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
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
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  for (const key of added) delete scope[key];
  await teardownDom(saved, { scope });
});

const noop = () => {};

const createLabel = (kind: string) => (kind === "browser" ? "New browser tab" : `New ${kind}`);
const choose = (row: HTMLElement) =>
  act(async () => {
    row.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
async function type(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  await act(async () => {
    field.acpmuxMarkdownField!.focus();
    field.acpmuxMarkdownField!.writeText(text, text.length, text.length);
  });
  expect(field.acpmuxMarkdownField!.value()).toBe(text);
}

test("Minimal's searchable create rows open a terminal, a browser tab and a chat", async () => {
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
    callNative: async (method, params) => {
      calls.push({ method, params });
      return method === "chat.new" ? "session-1" : undefined;
    },
    cwd: "/Users/you/src/app",
    chatCwd: "/Users/you/src/app",
    leave: () => left++,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  // Each action on its own page: a page opens one thing, then the tab is gone.
  let labels: (string | undefined)[] = [];
  for (const kind of ["terminal", "browser", "chat"]) {
    const root: Root = createRoot(host);
    try {
      await act(async () =>
        root.render(
          <QueryClientProvider client={new QueryClient()}>
            <NewTabScreen
              template="minimal"
              snapshot={noChat()}
              lastAgent="claude"
              cwd="/Users/you/src/app"
              {...actions}
            />
          </QueryClientProvider>,
        ),
      );
      expect(host.querySelector(".nt-screen[data-minimal]")).not.toBeNull();
      expect(host.querySelector(".nt-create")).toBeNull();
      await type("new");
      const rows = [...window.document.querySelectorAll<HTMLElement>('.nt-row[data-type="create"]')];
      labels = rows.map((row) => row.querySelector(".nt-row-title")?.textContent?.trim());
      const row = rows.find((row) => row.querySelector(".nt-row-title")?.textContent === createLabel(kind));
      expect(row, `no ${kind} create action`).toBeTruthy();
      await choose(row!);
    } finally {
      act(() => root.unmount());
    }
  }
  {
    expect(labels).toEqual(["New terminal", "New browser tab", "New chat"]);
    const opened = calls.filter((call) => call.method === "tab.open" || call.method === "chat.new");
    expect(opened).toEqual([
      // A terminal in the tab's folder, with nothing typed.
      {
        method: "tab.open",
        params: { kind: "terminal", text: "", run: false, inPlace: true, cwd: "/Users/you/src/app" },
      },
      // A browser tab on the new tab page (`browser.newTabPage`), with nothing to load.
      { method: "tab.open", params: { kind: "browser", text: "", inPlace: true } },
      // The page becomes a chat with the agent Return would ask, sending nothing.
      { method: "chat.new", params: expect.objectContaining({ harness: "claude" }) },
    ]);
    expect(calls.some((call) => call.method === "chat.send")).toBe(false);
    expect(left).toBe(1);
  }
});

test("New chat starts empty, and a second creation opens nothing more", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      calls.push({ method, params });
      return method === "chat.new" ? "session-1" : undefined;
    },
    cwd: "/Users/you/src/app",
    chatCwd: "/Users/you/src/app",
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const render = async (root: Root) =>
    act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <NewTabScreen
            template="minimal"
            snapshot={noChat()}
            lastAgent="claude"
            cwd="/Users/you/src/app"
            {...actions}
          />
        </QueryClientProvider>,
      ),
    );
  const row = (kind: string) =>
    [...window.document.querySelectorAll<HTMLElement>('.nt-row[data-type="create"]')].find(
      (row) => row.querySelector(".nt-row-title")?.textContent === createLabel(kind),
    )!;
  let root: Root = createRoot(host);
  try {
    await render(root);
    await type("new chat");
    await choose(row("chat"));
    expect(calls.filter((call) => call.method === "chat.new")).toHaveLength(1);
    expect(calls.filter((call) => call.method === "chat.send")).toEqual([]);
  } finally {
    act(() => root.unmount());
  }
  calls.length = 0;
  root = createRoot(host);
  try {
    await render(root);
    await type("new");
    // A double click (or a click during the terminal's spawn) opens one tab.
    await act(async () => {
      for (const kind of ["terminal", "terminal", "browser"])
        row(kind).dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    expect(calls.filter((call) => call.method === "tab.open").length).toBe(1);
  } finally {
    act(() => root.unmount());
  }
});
