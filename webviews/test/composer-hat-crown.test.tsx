// l10n-allow-file: test fixture subagent names, commands and chats, not shipped UI.
// Leading Pair composer crown (trayFoldHead.experiment.ts `crown`, SubagentTray.tsx):
// - Opaque recessed crown above the borderless composer (no .ui-glass).
// - Single item (finished subagent or running command): 1-line direct-click crown, no corner badge,
//   clicking navigates directly to the subagent or background command.
// - Multi-item header: separate monochrome 9+ icon sub-badges for subagents and commands side by side
//   on the left with no divider; command badge is non-clickable (header click toggles open/closed).
// - Steady hide and panel utility icons on the right; no shell group-hover fade.
// - Open list: flat direct-click rows with no divider, no working details, and no inline expansion.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom, trackReactScheduler } from "./support/domTeardown";

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
  cmuxExperiments: {},
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

trackReactScheduler();
const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { trayItems, finishedTrayItems } = await import("../src/agent-session/acpmux/subagents/runningTray");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

const now = Date.now();
const makeAgent = (id: string, task: string, overrides: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: id,
  task,
  state: "running",
  action: "Bash",
  background: true,
  startedAt: now - 45_000,
  harness: "claude",
  ...overrides,
});

const makeCommand = (id: string, command: string, overrides: Partial<BackgroundCommand> = {}): BackgroundCommand => ({
  id,
  command,
  processId: id,
  toolCallId: `call-${id}`,
  state: "running",
  startedAt: now - 20_000,
  ...overrides,
});

async function mount(props: Record<string, unknown>) {
  scope.cmuxExperiments = {};
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(
      createElement(SubagentTray, {
        items: [],
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
        ...props,
      }),
    ),
  );
  return {
    host,
    tray: () => host.querySelector<HTMLElement>(".acpmux-running-tray")!,
    head: () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!,
    done: async () => act(async () => root.unmount()),
  };
}

describe("Leading Pair composer crown", () => {
  test("single finished subagent renders a direct-click minimal crown with no badge and opens directly", async () => {
    const opened: string[] = [];
    const doneAgent = makeAgent("a1", "Improve todo.html", {
      state: "completed",
      endedAt: now - 1_000,
    });
    const { host, tray, head, done } = await mount({
      items: [],
      finished: finishedTrayItems([doneAgent], []),
      onOpen: (id: string) => opened.push(id),
      onTuck: () => {},
      onOpenPanel: () => {},
    });
    try {
      expect(tray().hasAttribute("data-crown")).toBe(true);
      expect(tray().classList.contains("ui-glass")).toBe(false);
      expect(host.querySelector(".acpmux-crown__sub-badge")).toBeNull();
      expect(host.querySelector(".acpmux-crown__chev")).toBeNull();
      expect(head().textContent).toContain("Improve todo.html");
      expect(host.querySelector(".acpmux-crown__state-word")?.textContent).toBe("Done");
      await act(async () => head().click());
      expect(opened).toEqual(["a1"]);
      expect(host.querySelector(".acpmux-running-tray__list")).toBeNull();
    } finally {
      await done();
    }
  });

  test("single running command navigates directly to the background command on click", async () => {
    const openedCmds: string[] = [];
    const cmd = makeCommand("c1", "bun test webviews/subagents", { description: "Run subagent tests" });
    const { host, head, done } = await mount({
      items: trayItems([], [cmd], [], true),
      onOpenCommand: (entry: BackgroundCommand) => openedCmds.push(entry.id),
      canOpenTerminal: false,
      canReadTail: true,
    });
    try {
      expect(host.querySelector(".acpmux-crown__sub-badge")).toBeNull();
      expect(head().textContent).toContain("Run subagent tests");
      await act(async () => head().click());
      expect(openedCmds).toEqual(["c1"]);
      expect(host.querySelector(".acpmux-running-tray__tail")).toBeNull();
    } finally {
      await done();
    }
  });

  test("multi-item header shows separate leading pair sub-badges with 9+ cap, non-clickable command badge, and no divider", async () => {
    const agents = Array.from({ length: 12 }, (_, idx) =>
      makeAgent(`a${idx}`, `Subagent task ${idx}`, {
        harness: idx % 2 === 0 ? "claude" : "codex",
        startedAt: now - (60 - idx) * 1000,
      }),
    );
    const cmds = [makeCommand("c1", "bun test"), makeCommand("c2", "cargo test")];
    const openedCmds: string[] = [];
    let tucked = 0;
    let panelOpened = 0;
    const { host, head, done } = await mount({
      items: trayItems(agents, cmds, [], true),
      onOpenCommand: (entry: BackgroundCommand) => openedCmds.push(entry.id),
      onTuck: () => {
        tucked += 1;
      },
      onOpenPanel: () => {
        panelOpened += 1;
      },
    });
    try {
      const agentBadge = host.querySelector('[data-badge-kind="agents"] .acpmux-crown__sub-badge');
      const cmdBadge = host.querySelector('[data-badge-kind="commands"] .acpmux-crown__sub-badge');
      expect(agentBadge?.textContent).toBe("9+");
      expect(cmdBadge?.textContent).toBe("2");
      // Command badge is a plain span inside the header button, not a separate clickable button.
      const cmdBadgeWrap = host.querySelector<HTMLElement>('[data-badge-kind="commands"]')!;
      expect(cmdBadgeWrap.tagName).toBe("SPAN");
      expect(cmdBadgeWrap.closest("button")).toBe(head());
      // Clicking the command badge toggles the hat open rather than jumping directly to a command.
      await act(async () => cmdBadgeWrap.click());
      expect(openedCmds).toEqual([]);
      expect(head().getAttribute("aria-expanded")).toBe("true");
      // Steady hide & panel buttons work independently without toggling the hat.
      const hideBtn = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__tuck")!;
      const panelBtn = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__open")!;
      expect(head().contains(hideBtn)).toBe(false);
      expect(head().contains(panelBtn)).toBe(false);
      await act(async () => hideBtn.click());
      await act(async () => panelBtn.click());
      expect(tucked).toBe(1);
      expect(panelOpened).toBe(1);
      expect(head().getAttribute("aria-expanded")).toBe("true");
    } finally {
      await done();
    }
  });

  test("open list rows have no divider, no working details, no expansion, and navigate directly on click", async () => {
    const opened: string[] = [];
    const stopped: string[] = [];
    const a1 = makeAgent("a1", "Refactor composer hat tokens", { action: "Read" });
    const a2 = makeAgent("a2", "Audit keyboard focus traps", { harness: "codex" });
    const c1 = makeCommand("c1", "bun test webviews/subagents", { description: "Run subagent tests" });
    const { host, head, done } = await mount({
      items: trayItems([a1, a2], [c1], [], true),
      onOpen: (id: string) => opened.push(`agent:${id}`),
      onOpenCommand: (entry: BackgroundCommand) => opened.push(`command:${entry.id}`),
      canReadTail: true,
      canOpenTerminal: false,
      stop: async (id: string) => {
        stopped.push(`agent:${id}`);
      },
      stopProcess: async (id: string) => {
        stopped.push(`process:${id}`);
      },
    });
    try {
      await act(async () => head().click());
      const rows = [...host.querySelectorAll<HTMLElement>(".acpmux-crown__row")];
      expect(rows.length).toBe(3);
      // No working detail lines and no inline expansion tails.
      expect(host.querySelector(".acpmux-agent-line__latest, .acpmux-agent-line__latest-inline")).toBeNull();
      expect(host.querySelector(".acpmux-running-tray__tail")).toBeNull();
      // Clicking subagent and command rows navigates directly instead of expanding.
      for (const row of rows) {
        await act(async () => row.querySelector<HTMLButtonElement>(".acpmux-crown__row-btn")!.click());
      }
      expect(opened).toEqual(["agent:a1", "agent:a2", "command:c1"]);
      expect(host.querySelector(".acpmux-running-tray__tail")).toBeNull();
      // Stop buttons live in fixed state-slots as siblings of row buttons and stop without navigating.
      const stopBtn = rows[0]!.querySelector<HTMLButtonElement>(".cv-subagent__stop")!;
      expect(rows[0]!.querySelector(".acpmux-crown__row-btn")!.contains(stopBtn)).toBe(false);
      await act(async () => stopBtn.click());
      expect(stopped).toEqual(["agent:a1"]);
      expect(opened).toHaveLength(3);
    } finally {
      await done();
    }
  });

  test("preserves head button identity on 1 -> 2 transition, renders fallback mark for unknown harness, and distinguishes waiting/failed/stopped states", async () => {
    scope.cmuxExperiments = {};
    resetTrayOpenMemory();
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    const a1 = makeAgent("a1", "Unknown harness run", { harness: undefined });
    const a2 = makeAgent("a2", "Waiting review", { harness: "codex" });
    const aFailed = makeAgent("a3", "Failed check", { state: "failed", endedAt: now - 1_000 });
    const aStopped = makeAgent("a4", "Stopped check", { state: "cancelled", endedAt: now - 1_000 });
    try {
      await act(async () =>
        root.render(
          createElement(SubagentTray, {
            items: trayItems([a1], [], [], true),
            working: true,
            waiting: new Set<string>(),
            onOpen: () => {},
          }),
        ),
      );
      const firstBtn = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      // Unknown harness still renders a fallback icon glyph (never blank space).
      expect(host.querySelector('[data-agent-mark="unknown"]')).toBeNull();
      expect(host.querySelector(".acpmux-crown__icon-glyph svg")).not.toBeNull();

      await act(async () =>
        root.render(
          createElement(SubagentTray, {
            items: trayItems([a1, a2], [], [], true),
            finished: finishedTrayItems([aFailed, aStopped], []),
            working: true,
            waiting: new Set<string>(["a2"]),
            onOpen: () => {},
          }),
        ),
      );
      // Same button node stays mounted across 1 -> multi transition.
      expect(host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")).toBe(firstBtn);
      // Multi-item header prioritizes waiting state when a subagent awaits input.
      expect(host.querySelector(".acpmux-crown__bar")?.getAttribute("data-status")).toBe("waiting");

      // Open list surfaces waiting/failed/stopped words without dimming waiting or failed rows.
      await act(async () => firstBtn.click());
      const rows = [...host.querySelectorAll<HTMLElement>(".acpmux-crown__row")];
      const byStatus = (s: string) => rows.find((r) => r.getAttribute("data-status") === s);
      expect(byStatus("waiting")?.hasAttribute("data-done")).toBe(false);
      expect(byStatus("failed")?.hasAttribute("data-done")).toBe(false);
      expect(byStatus("stopped")?.hasAttribute("data-done")).toBe(true);
      expect(byStatus("failed")?.querySelector(".acpmux-crown__state-word")?.textContent).toBe("Failed");
      expect(byStatus("stopped")?.querySelector(".acpmux-crown__state-word")?.textContent).toBe("Cancelled");

      // Escape folds the open crown list back to the header.
      await act(async () => {
        host
          .querySelector(".acpmux-running-tray")!
          .dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      });
      expect(firstBtn.getAttribute("aria-expanded")).toBe("false");
    } finally {
      await act(async () => root.unmount());
    }
  });
});
