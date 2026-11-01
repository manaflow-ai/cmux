// The New Tab composer's model menu always shows the harness rail (Leo 2026-10-31: "IM SAYING I
// CANT FUCKING SEE ANY HARNESS"). A pick or a typed prompt on the page starts its deferred chat
// behind it; that session's start row counted as a message, so the chips locked the harness and
// the menu dropped the rail to the plain list of one harness's models. A chat with a message keeps
// its own harness's list, as before.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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
  "ResizeObserver",
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
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
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
    // The composer's footer row fits its chips to its width (composerRowFit.ts) on every New Tab.
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
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
type Snap = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

const started = (rows: Snap["rows"]): Snap =>
  noChat([], {
    sessionId: "s-1",
    summary: { sessionId: "s-1", harness: "claude", model: "claude-opus-5-5", turnCount: 0 } as Snap["summary"],
    rows,
  });
const startRow = {
  kind: "sessionStart",
  id: "start-1",
  sessionStart: { harness: "claude" },
} as unknown as Snap["rows"][number];
const userRow = { kind: "user", id: "u-1", text: "hi" } as unknown as Snap["rows"][number];

/// The rail tabs the model menu shows after the chip is clicked (none: no rail).
async function railTabs(page: "newTab" | "chat", snapshot: Snap, typed?: string): Promise<string[]> {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { NewTabComposerChips, ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
  const actions = newTabScreenActions({
    callNative: async () => undefined,
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          {page === "newTab" ? (
            <NewTabScreen
              snapshot={snapshot}
              lastAgent="claude"
              cwd="/Users/you/src/app"
              chips={NewTabComposerChips}
              {...actions}
            />
          ) : (
            <ChatComposerChips snapshot={snapshot} />
          )}
        </QueryClientProvider>,
      ),
    );
    if (typed) {
      const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
      for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
        await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      field.acpmuxMarkdownField!.writeText(typed, typed.length, typed.length);
    }
    const trigger = window.document.querySelector<HTMLElement>("[data-menu=Model]");
    expect(trigger).not.toBeNull();
    await act(async () => trigger!.click());
    expect(window.document.querySelector(".acpmux-quick-menu")).not.toBeNull();
    return [...window.document.querySelectorAll(".acpmux-quick-rail-tab")].map(
      (tab) => tab.getAttribute("aria-label") ?? "",
    );
  } finally {
    await act(async () => root.unmount());
    window.document.body.querySelectorAll(".ui-popup").forEach((node) => node.remove());
  }
}

test("a New Tab's model menu shows the harness rail before its deferred chat starts", async () => {
  const tabs = await railTabs("newTab", noChat(), "helo");
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
});

test("a New Tab's model menu keeps the harness rail once its deferred chat has started behind it", async () => {
  const tabs = await railTabs("newTab", started([startRow]), "helo");
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
});

test("a fresh chat whose only row is its session start can still pick another harness", async () => {
  const tabs = await railTabs("chat", started([startRow]));
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
});

test("a chat with a message keeps its own harness's models, with no rail", async () => {
  expect(await railTabs("chat", started([startRow, userRow]))).toEqual([]);
});
