// l10n-allow-file: test fixture commands, not shipped UI.
import { afterAll, describe, expect, test } from "bun:test";
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
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { trayItems } = await import("../src/agent-session/acpmux/subagents/runningTray");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { TrayPullTab, tuckTray } = await import("../src/agent-session/acpmux/subagents/TrayPullTab");
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
const { registerChatDisplayHost, setChatDisplay, useTrayTucked, TRAY_TUCKED_KEY } =
  await import("../src/agent-session/acpmux/chatDisplay");
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;

// The composer hat tucks away (Leo, 2026-11-04: "what if you wanted to collapse that one line?"):
// a chevron at the hat's top middle tucks it, `agentPane.display.trayTucked` holds it, and tucked
// only a pull tab at the composer's top middle stays, whose click brings the hat back (App.tsx).
afterAll(() => {
  registerChatDisplayHost(undefined);
  setChatDisplay({});
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

const now = Date.now();
const commands: BackgroundCommand[] = [
  { id: "c1", command: "bun run dev", state: "running", startedAt: now - 60_000, description: "Start the dev server" },
  { id: "c2", command: "bun test", state: "running", startedAt: now - 30_000, description: "Watch the tests" },
];

/// What App.tsx draws in the bottom stack: the hat, or tucked, its pull tab.
function Stack() {
  const tucked = useTrayTucked();
  return tucked
    ? createElement(TrayPullTab, { running: true })
    : createElement(SubagentTray, {
        items: trayItems([], commands, [], true),
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
        onTuck: tuckTray,
      });
}

describe("the composer hat tucks away and comes back", () => {
  test("the hat's chevron tucks it, the pull tab brings it back, and the host writes the setting", async () => {
    resetTrayOpenMemory();
    setChatDisplay({});
    const writes: [string, unknown][] = [];
    registerChatDisplayHost((key, value) => writes.push([key, value]));
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () => root.render(createElement(Stack)));
    try {
      expect(host.querySelector(".acpmux-running-tray")).not.toBeNull();
      expect(host.querySelector(".acpmux-tray-pull")).toBeNull();
      const tuck = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__tuck")!;
      expect(tuck.getAttribute("aria-label")).toBe("Tuck Away");
      await act(async () => tuck.click());
      expect(host.querySelector(".acpmux-running-tray")).toBeNull();
      const tab = host.querySelector<HTMLButtonElement>(".acpmux-tray-pull__tab")!;
      expect(tab.getAttribute("aria-label")).toBe("Show Running Work");
      await act(async () => tab.click());
      expect(host.querySelector(".acpmux-running-tray")).not.toBeNull();
      // The page sends the host one write 250 ms after the last change (chatDisplay.ts WRITE_DELAY_MS).
      // fixed-wait: that coalesced, delayed host write is the behavior under test.
      await act(async () => new Promise((resolve) => setTimeout(resolve, 300)));
      // The last write wins: brought back, the key is removed (the default, shown).
      expect(writes).toEqual([[TRAY_TUCKED_KEY, null]]);
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("the host's value tucks it: the palette, the CLI and MCP write the same key", async () => {
    resetTrayOpenMemory();
    registerChatDisplayHost(undefined);
    setChatDisplay({});
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () => root.render(createElement(Stack)));
    try {
      await act(async () => setChatDisplay({ [TRAY_TUCKED_KEY]: true }));
      expect(host.querySelector(".acpmux-running-tray")).toBeNull();
      expect(host.querySelector(".acpmux-tray-pull")).not.toBeNull();
      await act(async () => setChatDisplay({ [TRAY_TUCKED_KEY]: false }));
      expect(host.querySelector(".acpmux-running-tray")).not.toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("a hat without onTuck (Quick Chat, the transcript placement) draws no chevron", async () => {
    setChatDisplay({});
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () =>
      root.render(
        createElement(SubagentTray, {
          items: trayItems([], commands, [], true),
          working: true,
          waiting: new Set<string>(),
          onOpen: () => {},
        }),
      ),
    );
    try {
      expect(host.querySelector(".acpmux-running-tray__tuck")).toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("tucked, the tab says how many run and draws a dot for one that needs the person", async () => {
    setChatDisplay({});
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () => root.render(createElement(TrayPullTab, { running: true, count: 3, waiting: 1 })));
    try {
      const tab = host.querySelector<HTMLButtonElement>(".acpmux-tray-pull__tab")!;
      expect(tab.getAttribute("aria-label")).toBe("Show Running Work · 3 running · 1 waiting on you");
      expect(tab.hasAttribute("data-waiting")).toBe(true);
      expect(host.querySelector(".acpmux-tray-pull__count")?.textContent).toBe("3");
      expect(host.querySelector(".acpmux-tray-pull__dot")).not.toBeNull();
      // The middle unless the side experiment says otherwise (Leo: "maybe the left… or the right…").
      expect(host.querySelector(".acpmux-tray-pull")?.getAttribute("data-side")).toBe("center");
      await act(async () => root.render(createElement(TrayPullTab, { running: false })));
      expect(tab.getAttribute("aria-label")).toBe("Show Running Work");
      expect(host.querySelector(".acpmux-tray-pull__badge")).toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("the side experiment moves the tab to an end", async () => {
    const scoped = globalThis as { cmuxExperiments?: Record<string, string> };
    const before = scoped.cmuxExperiments;
    scoped.cmuxExperiments = { "subagent-tray-grabber": "right" };
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    try {
      await act(async () => root.render(createElement(TrayPullTab, { running: true })));
      expect(host.querySelector(".acpmux-tray-pull")?.getAttribute("data-side")).toBe("right");
    } finally {
      await act(async () => root.unmount());
      scoped.cmuxExperiments = before;
    }
  });
});
