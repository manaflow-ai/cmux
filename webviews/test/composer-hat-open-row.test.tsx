// l10n-allow-file: test fixture subagent names, commands and chats, not shipped UI.
// The composer hat's `row` arm (hatOpen.experiment.ts; Lawrence, 2026-11-20: "ui for opening subagents
// is very confusing"): a click on the whole line opens what it stands for, and the chevron is a button of
// its own that expands the details in place. A line whose row has nothing to open (a host with no
// terminal for a command, no chat view for a started chat) keeps today's one chevron, so no two controls
// on a line do the same thing.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
  // The arm, as the gallery's stage frame pins it (experiments/experiment.ts, source 1).
  cmuxExperiments: { "composer-hat-open": "row" },
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
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;
type StartedSession = import("../src/agent-session/acpmux/started/startedSessions").StartedSession;

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

const now = Date.now();
const reviewer: Subagent = {
  id: "agent-reviewer",
  parent: null,
  name: "Reviewer",
  task: "Review the fold motion",
  state: "running",
  background: true,
  startedAt: now - 60_000,
};
const watcher: BackgroundCommand = {
  id: "s/1",
  command: "bun test --watch",
  processId: "s/1",
  toolCallId: "call-watch",
  state: "running",
  startedAt: now - 30_000,
};
const port: StartedSession = {
  subsession: true,
  sessionId: "c1",
  title: "Port the history page",
  state: "running",
  doing: "Read HistoryPage.tsx",
};
const items = trayItems([reviewer], [watcher], [port], false);

async function mount(props: Record<string, unknown>) {
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(
      createElement(SubagentTray, { items, working: false, waiting: new Set<string>(), onOpen: () => {}, ...props }),
    ),
  );
  const head = host.querySelector<HTMLButtonElement>('.acpmux-running-tray__head[aria-expanded="false"]');
  if (head) await act(async () => head.click());
  // A failed lookup prints every line's text, not an undefined.
  const names = () =>
    [...host.querySelectorAll<HTMLElement>(".acpmux-agent-line__button")].map((node) => node.textContent);
  const find = (name: string) => {
    const found = [...host.querySelectorAll<HTMLElement>(".acpmux-agent-line")].find((node) =>
      node.querySelector(".acpmux-agent-line__button")?.textContent?.includes(name),
    );
    if (!found) throw new Error(`no line holds ${JSON.stringify(name)}: ${JSON.stringify(names())}`);
    return found;
  };
  return { host, line: find, done: async () => act(async () => root.unmount()) };
}

describe("the composer hat's row arm", () => {
  test("the whole row opens each kind of line; the chevron only expands its details", async () => {
    const opened: string[] = [];
    const { host, line, done } = await mount({
      onOpen: (id: string) => opened.push(`agent:${id}`),
      onOpenCommand: (entry: BackgroundCommand) => opened.push(`command:${entry.id}`),
      onOpenSession: (id: string) => opened.push(`chat:${id}`),
      canReadTail: true,
    });
    try {
      expect(host.querySelector(".acpmux-running-tray")?.getAttribute("data-open-look")).toBe("row");
      for (const name of ["Review the fold motion", "bun test", "Port the history page"])
        await act(async () => line(name).querySelector<HTMLButtonElement>(".acpmux-agent-line__button")!.click());
      expect(opened).toEqual(["agent:agent-reviewer", "command:s/1", "chat:c1"]);
      // Each line has one details button, and it opens nothing.
      for (const name of ["Review the fold motion", "bun test", "Port the history page"]) {
        const disclose = line(name).querySelectorAll<HTMLButtonElement>(".acpmux-agent-line__disclose");
        expect(disclose.length).toBe(1);
        expect(disclose[0]!.getAttribute("aria-expanded")).toBe("false");
        await act(async () => disclose[0]!.click());
        expect(disclose[0]!.getAttribute("aria-expanded")).toBe("true");
      }
      expect(opened).toHaveLength(3);
    } finally {
      await done();
    }
  });

  test("a line whose row has nothing to open keeps one chevron that expands it, as today", async () => {
    const opened: string[] = [];
    // No terminal to open and no chat view: the command's row and the chat's row only expand.
    const { line, done } = await mount({ onOpen: (id: string) => opened.push(`agent:${id}`), canReadTail: true });
    try {
      for (const name of ["bun test", "Port the history page"]) {
        const row = line(name);
        expect(row.querySelector(".acpmux-agent-line__disclose")).toBeNull();
        const button = row.querySelector<HTMLButtonElement>(".acpmux-agent-line__button")!;
        expect(button.getAttribute("aria-expanded")).toBe("false");
        await act(async () => button.click());
        expect(button.getAttribute("aria-expanded")).toBe("true");
      }
      expect(opened).toEqual([]);
    } finally {
      await done();
    }
  });
});
