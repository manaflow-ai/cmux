// The Default template's page follows Claude Code desktop's new-session screen (Leo 2026-10-19): the
// composer at the foot of the page, and over it, centered, an environment card and a suggested
// actions card; the recent chats never sit between them and the composer.
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
  session({
    sessionId: "s-input",
    title: "Ship the release notes",
    indicator: "input",
    cwd: "/Users/you/src/app",
    updatedAt: Date.now() - 60_000,
  }),
  session({ sessionId: "s-idle", title: "Index the docs", cwd: "/Users/you/src/app", updatedAt: Date.now() - 120_000 }),
];

const PROJECTS = [
  { cwd: "/Users/you/src/app", label: "app" },
  { cwd: "/Users/you/src/web", label: "web" },
];

async function render(template: "default" | "threads" = "default", projects = PROJECTS) {
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
          projects={projects}
          {...(template ? { template } : {})}
          {...props}
        />
      </QueryClientProvider>,
    ),
  );
  return root;
}

test("the Default template is Claude Code desktop's page: cards over the composer at the foot", async () => {
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
    expect(env.querySelector("hr.nt-stage-divider")).toBeTruthy();
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
    // Default's own composer, only placed at the foot (#22285 keeps the second dot's composer): the
    // folder strip over the box, Send in it, and no Claude Code quiet row under it.
    expect(composer!.querySelector(".nt-above .nt-location")).toBeTruthy();
    expect(composer!.querySelector(".nt-box .nt-location")).toBeNull();
    expect(composer!.querySelector(".nt-box .nt-send")).toBeTruthy();
    expect(composer!.querySelector(".nt-foot")).toBeNull();
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
    expect(screen.querySelector(".nt-composer .nt-above .nt-location")).toBeTruthy();
  } finally {
    act(() => root.unmount());
  }
});

// Review (PR 22119, Greptile): the needs-you rows were picked from the five recent cards, so an
// older failed chat behind five newer idle ones showed nowhere. They come from every chat now.
test("an older failed chat behind newer idle ones still shows as needing you", async () => {
  const { needsYouCards } = await import("../src/agent-session/acpmux/newtab/screenModel");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const now = Date.now();
  const idle = Array.from({ length: 6 }, (_, index) =>
    session({ sessionId: `s-idle-${index}`, title: `Idle ${index}`, updatedAt: now - (index + 1) * 60_000 }),
  );
  const failed = session({
    sessionId: "s-failed",
    title: "Old failure",
    indicator: "failed",
    updatedAt: now - 3_600_000,
  });
  const cards = needsYouCards([...idle, failed], now, translate);
  expect(cards.map((card) => card.sessionId)).toEqual(["s-failed"]);
});

// Review (PR 22119, Greptile P0): the needs-you rows come from one pass that keeps three, in
// recentSessions' order (asking first, then newest), never from a sort of every chat.
test("the needs-you rows keep the first three: chats asking first, then the newest failures", async () => {
  const { needsYouCards } = await import("../src/agent-session/acpmux/newtab/screenModel");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const now = Date.now();
  const make = (id: string, indicator: "input" | "failed" | "lost" | "done", minutes: number) =>
    session({ sessionId: id, title: id, indicator, updatedAt: now - minutes * 60_000 });
  const chats = [
    make("failed-new", "failed", 1),
    make("idle", "done", 0),
    make("lost-old", "lost", 50),
    make("asking-old", "input", 40),
    make("failed-mid", "failed", 10),
    make("asking-new", "input", 5),
    make("failed-oldest", "failed", 90),
  ];
  expect(needsYouCards(chats, now, translate).map((card) => card.sessionId)).toEqual([
    "asking-new",
    "asking-old",
    "failed-new",
  ]);
  expect(needsYouCards(chats, now, translate, 5).map((card) => card.sessionId)).toEqual([
    "asking-new",
    "asking-old",
    "failed-new",
    "failed-mid",
    "lost-old",
  ]);
});

// Review (PR 22119, Greptile P2): a chat with no project runs in a private agent-home folder that
// App lists among the projects; the environment card never offers it by its workspace id.
test("the environment card lists no private agent-home folder", async () => {
  const home = "/Users/you/Library/Application Support/cmux/agent-home/ws-0f3a9c";
  const root = await render("default", [{ cwd: home, label: "ws-0f3a9c" }, ...PROJECTS]);
  try {
    const env = host.querySelector(".nt-env")!;
    const rows = [...env.querySelectorAll(".nt-stage-row")].map((row) => row.textContent ?? "");
    expect(rows.join("|")).toContain("web");
    expect(rows.join("|")).not.toContain("ws-0f3a9c");
  } finally {
    act(() => root.unmount());
  }
});
