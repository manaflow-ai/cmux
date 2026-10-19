// The default New Tab layout follows Claude Code desktop's new-session screen (Leo 2026-10-19): the
// composer at the foot of the page with the plain footer, and over it, centered, an environment card
// and a suggested actions card; the recent chats never sit between the composer and its footer.
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

const actions = async () => {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
  return newTabScreenActions({
    callNative: async () => undefined,
    cwd: "/Users/you/src/app",
    chatCwd: "/Users/you/src/app",
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
};

const sessions = () => [
  session({ sessionId: "s-input", title: "Ship the release notes", indicator: "input", cwd: "/Users/you/src/app", updatedAt: Date.now() - 60_000 }),
  session({ sessionId: "s-idle", title: "Index the docs", cwd: "/Users/you/src/app", updatedAt: Date.now() - 120_000 }),
];

const PROJECTS = [
  { cwd: "/Users/you/src/app", label: "app" },
  { cwd: "/Users/you/src/web", label: "web" },
];

async function render(template?: "default" | "threads") {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  const props = await actions();
  await act(async () =>
    root.render(
      <QueryClientProvider client={new QueryClient()}>
        <NewTabScreen
          snapshot={noChat(sessions())}
          lastAgent="claude"
          cwd="/Users/you/src/app"
          projects={PROJECTS}
          {...(template ? { template } : {})}
          {...props}
        />
      </QueryClientProvider>,
    ),
  );
  return root;
}

test("the default New Tab is Claude Code desktop's layout: cards over the composer at the foot", async () => {
  const root = await render();
  try {
    const screen = host.querySelector(".nt-screen")!;
    expect(screen.getAttribute("data-layout")).toBe("stage");
    // The stage comes first, the composer last: nothing over it can push the composer.
    const stage = screen.querySelector(":scope > .nt-stage");
    const composer = screen.querySelector(":scope > .nt-composer");
    expect(stage).toBeTruthy();
    expect(composer).toBeTruthy();
    expect(stage!.compareDocumentPosition(composer!) & window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    // The recent chats live in the stage, never between the composer and its footer.
    expect(composer!.querySelector(".nt-cards, .nt-chats")).toBeNull();
    // The environment card: the chat's project checked, then the other projects and Choose environment.
    const env = stage!.querySelector(".nt-env")!;
    const rows = [...env.querySelectorAll(".nt-stage-row")];
    expect(rows[0]?.getAttribute("aria-pressed")).toBe("true");
    expect(rows[0]?.textContent).toContain("app");
    expect(rows.map((row) => row.textContent).join("|")).toContain("web");
    expect(env.querySelector("[role=separator]")).toBeTruthy();
    expect(env.textContent).toContain("Choose environment");
    // The suggestions card: the chat that needs you, then the three create actions, as rows.
    const suggest = stage!.querySelector(".nt-suggest")!;
    expect([...suggest.querySelectorAll(".nt-suggest-chat")].map((row) => row.textContent)).toEqual([
      expect.stringContaining("Ship the release notes"),
    ]);
    expect([...suggest.querySelectorAll(".nt-create [data-create]")].map((b) => b.textContent?.trim())).toEqual([
      "New terminal",
      "New browser tab",
      "New chat",
    ]);
    // No ghost pills: the create actions are rows of the card.
    expect(host.querySelector(".nt-create.ui-ghost-row")).toBeNull();
    // The footer: the folder strip moved into it, before the chips, with the plain look.
    const pickers = composer!.querySelector(".nt-pickers")!;
    expect(pickers.getAttribute("data-footer-look")).toBe("plain");
    expect(pickers.querySelector(".nt-location")).toBeTruthy();
    expect(composer!.querySelector(":scope > .nt-location")).toBeNull();
  } finally {
    act(() => root.unmount());
  }
});

test("the other templates keep the composer at the top of the page", async () => {
  const root = await render("threads");
  try {
    const screen = host.querySelector(".nt-screen")!;
    expect(screen.getAttribute("data-layout")).toBeNull();
    expect(screen.querySelector(".nt-stage")).toBeNull();
    expect(screen.querySelector(".nt-composer > .nt-location")).toBeTruthy();
  } finally {
    act(() => root.unmount());
  }
});
