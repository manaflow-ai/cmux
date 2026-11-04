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
const { pullTabCounts, TrayPullTab, tuckTray } = await import("../src/agent-session/acpmux/subagents/TrayPullTab");
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
const { registerChatDisplayHost, setChatDisplay, useTrayHandle, useTrayTucked, TRAY_HANDLE_KEY, TRAY_TUCKED_KEY } =
  await import("../src/agent-session/acpmux/chatDisplay");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
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

const CHAT = "chat-1";
const reviewer: Subagent = {
  id: "agent-reviewer",
  parent: null,
  name: "Reviewer",
  task: "Review the diff",
  state: "running",
  startedAt: now - 20_000,
};

/// What App.tsx draws in the bottom stack: the hat, or tucked, its pull tab.
function Stack({ agents = [], waiting = new Set<string>() }: { agents?: Subagent[]; waiting?: Set<string> }) {
  const tucked = useTrayTucked();
  const side = useTrayHandle();
  const items = trayItems(agents, commands, [], true);
  return tucked
    ? createElement(TrayPullTab, { chat: CHAT, ...pullTabCounts(items, waiting), working: false, side })
    : createElement(SubagentTray, {
        chat: CHAT,
        items,
        working: true,
        waiting,
        onOpen: () => {},
        onTuck: tuckTray,
        tuckSide: side,
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
      expect(tab.getAttribute("aria-label")).toBe("Show Running Work · 2 running");
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

  // Leo said "Yes" (2026-11-04) to "the tucked state, the hover tab with its dot or count", and asked
  // about "the grabber/dogear/whatever design thing on maybe the left… or the right…".
  test("tucked, the tab counts what runs, and a dot replaces the count while something waits on you", async () => {
    resetTrayOpenMemory();
    registerChatDisplayHost(undefined);
    setChatDisplay({ [TRAY_TUCKED_KEY]: true });
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () => root.render(createElement(Stack, { agents: [reviewer] })));
    try {
      expect(host.querySelector(".acpmux-tray-pull__count")?.textContent).toBe("3");
      expect(host.querySelector(".acpmux-tray-pull__dot")).toBeNull();
      await act(async () => root.render(createElement(Stack, { agents: [reviewer], waiting: new Set([reviewer.id]) })));
      expect(host.querySelector(".acpmux-tray-pull__dot")).not.toBeNull();
      expect(host.querySelector(".acpmux-tray-pull__count")).toBeNull();
      expect(host.querySelector(".acpmux-tray-pull")?.hasAttribute("data-waiting")).toBe(true);
      expect(host.querySelector(".acpmux-tray-pull__tab")?.getAttribute("aria-label")).toBe(
        "Show Running Work · 1 waiting · 2 running",
      );
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("a click brings the hat back folded; Option-click brings it back opened", async () => {
    registerChatDisplayHost(undefined);
    const host = dom.window.document.getElementById("root")!;
    for (const altKey of [false, true]) {
      resetTrayOpenMemory();
      setChatDisplay({ [TRAY_TUCKED_KEY]: true });
      const root = createRoot(host);
      await act(async () => root.render(createElement(Stack)));
      try {
        const tab = host.querySelector<HTMLButtonElement>(".acpmux-tray-pull__tab")!;
        await act(async () => {
          tab.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, altKey }));
        });
        const tray = host.querySelector(".acpmux-running-tray");
        expect(tray).not.toBeNull();
        expect(tray!.hasAttribute("data-open")).toBe(altKey);
      } finally {
        await act(async () => root.unmount());
      }
    }
  });

  test("the handle sits at the middle by default, or at the left or right the setting names", async () => {
    resetTrayOpenMemory();
    registerChatDisplayHost(undefined);
    setChatDisplay({});
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () => root.render(createElement(Stack)));
    try {
      expect(host.querySelector(".acpmux-running-tray")?.getAttribute("data-tucks")).toBe("middle");
      await act(async () => setChatDisplay({ [TRAY_HANDLE_KEY]: "right" }));
      expect(host.querySelector(".acpmux-running-tray")?.getAttribute("data-tucks")).toBe("right");
      await act(async () => setChatDisplay({ [TRAY_HANDLE_KEY]: "left", [TRAY_TUCKED_KEY]: true }));
      expect(host.querySelector(".acpmux-tray-pull")?.getAttribute("data-side")).toBe("left");
      // A value the schema refuses reads as the default.
      await act(async () => setChatDisplay({ [TRAY_HANDLE_KEY]: "top", [TRAY_TUCKED_KEY]: true }));
      expect(host.querySelector(".acpmux-tray-pull")?.getAttribute("data-side")).toBe("middle");
    } finally {
      await act(async () => root.unmount());
    }
  });
});
