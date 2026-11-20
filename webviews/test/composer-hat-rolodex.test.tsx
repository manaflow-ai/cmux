// l10n-allow-file: test fixture subagent tasks and commands, not shipped UI.
// The composer hat's stacked marks are a Rolodex (subagents/hatRolodex.experiment.ts). Leo,
// 2026-11-20, on Lawrence's "ui for opening subagents is very confusing": "we need to be able to like
// thumb through them like a Rolodex ... if you hover over them ... perhaps the text itself maybe
// changes like on the top of the composer hat ... you can click into them and be able to open up that
// sub-agent". Hovering a mark names its line in the header; a click on a mark opens that line and never
// folds or opens the hat; off the marks the header still folds and opens it; the `off` arm keeps the
// marks inert.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
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
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

const experiments = globalThis as { cmuxExperiments?: Record<string, string> };
afterEach(() => {
  delete experiments.cmuxExperiments;
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

const now = Date.now();
const agent = (id: string, task: string, startedAgo: number, action?: string): Subagent => ({
  id,
  parent: null,
  name: id,
  task,
  state: "running",
  startedAt: now - startedAgo,
  ...(action ? { action } : {}),
});
const command = (id: string, line: string, startedAgo: number, description?: string): BackgroundCommand => ({
  id,
  command: line,
  state: "running",
  startedAt: now - startedAgo,
  ...(description ? { description } : {}),
});

async function hat(agents: Subagent[], commands: BackgroundCommand[]) {
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const opened: string[] = [];
  const openedCommands: string[] = [];
  const items = trayItems(agents, commands, [], true);
  await act(async () =>
    root.render(
      createElement(SubagentTray, {
        items,
        working: true,
        waiting: new Set<string>(),
        onOpen: (id: string) => opened.push(id),
        onOpenCommand: (one: BackgroundCommand) => openedCommands.push(one.id),
      }),
    ),
  );
  const button = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
  const thumb = (key: string) => host.querySelector<HTMLElement>(`[data-rolodex-key="${key}"]`);
  const hover = async (node: Element) =>
    act(async () => {
      node.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: button }));
    });
  const leave = async (node: Element) =>
    act(async () => {
      node.dispatchEvent(new dom.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: button }));
    });
  return {
    host,
    button,
    opened,
    openedCommands,
    thumb,
    hover,
    leave,
    title: () => button.querySelector(".acpmux-running-tray__title")?.textContent,
    done: async () => act(async () => root.unmount()),
  };
}

describe("the composer hat's marks are a Rolodex", () => {
  test("hovering a mark names its line in the header; leaving the marks gives the header back", async () => {
    const bar = await hat(
      [agent("a1", "Review the tray", 50_000, "Read SubagentTray.tsx"), agent("a2", "Audit the stack", 3_000)],
      [],
    );
    try {
      expect(bar.title()).toBe("Review the tray");
      const second = bar.thumb("agent:a2") ?? bar.host.querySelectorAll("[data-rolodex-key]")[1];
      expect(second).toBeTruthy();
      await bar.hover(second!);
      expect(bar.title()).toContain("Audit the stack");
      expect(second!.hasAttribute("data-peeked")).toBe(true);
      // The other names' "+1 more" gives way while one mark is named.
      expect(bar.button.querySelector(".acpmux-running-tray__more")).toBeNull();
      const stack = bar.host.querySelector(".acpmux-running-tray__stack")!;
      await bar.leave(stack);
      expect(bar.title()).toBe("Review the tray");
    } finally {
      await bar.done();
    }
  });

  test("a click on a subagent's mark opens that subagent and leaves the hat folded", async () => {
    const bar = await hat([agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000)], []);
    try {
      const marks = [...bar.host.querySelectorAll<HTMLElement>("[data-rolodex-key]")];
      expect(marks.length).toBe(2);
      await act(async () => marks[1].click());
      expect(bar.opened).toEqual(["a2"]);
      expect(bar.button.getAttribute("aria-expanded")).toBe("false");
      // Off the marks, the header still folds and opens the hat.
      await act(async () => bar.button.click());
      expect(bar.button.getAttribute("aria-expanded")).toBe("true");
      expect(bar.opened).toEqual(["a2"]);
    } finally {
      await bar.done();
    }
  });

  test("the commands' shared mark opens a lone command's terminal, else opens the hat on its lines", async () => {
    const one = await hat(
      [agent("a1", "Review the tray", 50_000)],
      [command("c1", "bun run dev", 9_000, "Dev server")],
    );
    try {
      const mark = one.thumb("commands")!;
      expect(mark).toBeTruthy();
      await one.hover(mark);
      expect(one.title()).toContain("Dev server");
      await act(async () => mark.click());
      expect(one.openedCommands).toEqual(["c1"]);
      expect(one.button.getAttribute("aria-expanded")).toBe("false");
    } finally {
      await one.done();
    }
    const two = await hat(
      [agent("a1", "Review the tray", 50_000)],
      [command("c1", "bun run dev", 9_000, "Dev server"), command("c2", "bun run lint", 2_000, "Lint the web")],
    );
    try {
      const mark = two.thumb("commands")!;
      await two.hover(mark);
      expect(two.title()).toBe("Dev server · Lint the web");
      await act(async () => mark.click());
      expect(two.openedCommands).toEqual([]);
      expect(two.button.getAttribute("aria-expanded")).toBe("true");
    } finally {
      await two.done();
    }
  });

  test("the `off` arm keeps the marks inert: a click on one folds and opens the hat", async () => {
    experiments.cmuxExperiments = { "composer-hat-rolodex": "off" };
    const bar = await hat([agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000)], []);
    try {
      expect(bar.host.querySelector("[data-rolodex-key]")).toBeNull();
      const mark = bar.host.querySelector<HTMLElement>(".acpmux-running-tray__stack-mark")!;
      await act(async () => mark.click());
      expect(bar.opened).toEqual([]);
      expect(bar.button.getAttribute("aria-expanded")).toBe("true");
    } finally {
      await bar.done();
    }
  });
});
