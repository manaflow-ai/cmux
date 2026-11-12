// l10n-allow-file: test fixture subagent tasks and commands, not shipped UI.
// The running tray's folded header names what runs (Leo, 2026-11-03: "the "running" bar above the
// composer is currently no longer usable bc it doesn't display much", on a bar that read only
// "1 subagent running · 1 command 4s"). Folded, it reads as Claude Code's running-tasks list does:
// the subagent's task and the command's description (its short command when it has none), the
// newest one, then a count of the rest: one name that fits beats two cut ones (Leo, 2026-11-03, on a
// bar whose two names were both cut). Open, the lines list them newest first ("this previews one of
// the latest but it doesn't show in latest it shows in oldest order"), and the header keeps its
// counts. The folded bar's one name is now the longest-running item, which holds the lead until it
// ends (subagents/trayHeadOrder.ts): with 60 background commands, naming the newest swapped the
// header on every start (Leo, 2026-11-11: "the animation system is so borked and unintegrated").
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

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

const now = Date.now();
const agent = (id: string, task: string, startedAgo: number): Subagent => ({
  id,
  parent: null,
  name: id,
  task,
  state: "running",
  startedAt: now - startedAgo,
});
const command = (id: string, line: string, startedAgo: number, description?: string): BackgroundCommand => ({
  id,
  command: line,
  state: "running",
  startedAt: now - startedAgo,
  ...(description ? { description } : {}),
});

async function head(agents: Subagent[], commands: BackgroundCommand[]) {
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const items = trayItems(agents, commands, [], true);
  await act(async () =>
    root.render(createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} })),
  );
  const button = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
  return {
    button,
    title: () => button.querySelector(".acpmux-running-tray__title")?.textContent,
    more: () => button.querySelector(".acpmux-running-tray__more")?.textContent ?? "",
    time: () => host.querySelector(".acpmux-running-tray__head .acpmux-running-tray__time")?.textContent ?? "",
    rerender: async (agents: Subagent[], commands: BackgroundCommand[]) =>
      act(async () =>
        root.render(
          createElement(SubagentTray, {
            items: trayItems(agents, commands, [], true),
            working: true,
            waiting: new Set<string>(),
            onOpen: () => {},
          }),
        ),
      ),
    done: async () => act(async () => root.unmount()),
  };
}

describe("the folded running bar names what runs", () => {
  test("one subagent and one command: the longest-running one's name, then a count of the other", async () => {
    const bar = await head(
      [agent("a1", "Explore how the daemon updates itself", 2_000)],
      [command("c1", "cd ~/app && bun test --watch", 4_000, "Watch the tests")],
    );
    try {
      expect(bar.button.getAttribute("aria-expanded")).toBe("false");
      expect(bar.title()).toBe("Watch the tests");
      expect(bar.more()).toBe("+1 more");
      // Open, the lines name them and the header goes back to its counts.
      await act(async () => bar.button.click());
      expect(bar.title()).toBe("1 subagent running · 1 test run");
    } finally {
      await bar.done();
    }
  });

  test("a command with no description is named by its short command", async () => {
    const bar = await head(
      [agent("a1", "Review the tray", 1_000)],
      [command("c1", "cd ~/Projects/app && bun run dev", 9_000)],
    );
    try {
      expect(bar.title()).toBe("bun run dev");
    } finally {
      await bar.done();
    }
  });

  test("a substitution-based check has the same readable title in the folded header", async () => {
    const raw = "SHA=$(git rev-parse HEAD); cmux-ci run --class light --ref $SHA --script scripts/check-glyphs.sh";
    const bar = await head([agent("a1", "Review the tray", 1_000)], [command("c1", raw, 9_000)]);
    try {
      expect(bar.title()).toBe("git rev-parse HEAD · cmux-ci run");
      expect(bar.title()).not.toContain("HEAD);");
      expect(bar.more()).toBe("+1 more");
    } finally {
      await bar.done();
    }
  });

  test("five running: the longest-running one by name, then a count of the rest", async () => {
    const bar = await head(
      [
        agent("a1", "Review the tray", 50_000),
        agent("a2", "Review the fold", 40_000),
        agent("a3", "Audit the stack", 3_000),
      ],
      [
        command("c1", "bun run dev", 30_000, "Run the dev server"),
        command("c2", "bun run lint", 1_000, "Lint the web"),
      ],
    );
    try {
      expect(bar.title()).toBe("Review the tray");
      expect(bar.more()).toBe("+4 more");
    } finally {
      await bar.done();
    }
  });
});

describe("the folded running bar's clock is the run's", () => {
  // Review of cmux#41078: a lone item's header showed its own time, so the 100-minute lead ending
  // left a 10-minute one, and the clock went back by 90 minutes.
  test("the longest-running item ends and one is left: the clock keeps the run's start", async () => {
    const long = agent("a1", "Review the tray", 100 * 60_000);
    const short = command("c1", "bun run dev", 10 * 60_000, "Run the dev server");
    const bar = await head([long], [short]);
    try {
      const before = bar.time();
      expect(before).toContain("1h 40m");
      await bar.rerender([], [short]);
      expect(bar.time()).toContain("1h 40m");
    } finally {
      await bar.done();
    }
  });
});

describe("the open running tray lists what runs newest first", () => {
  test("subagents, commands and their order: the newest on top, a nested subagent under its parent", () => {
    const items = trayItems(
      [
        agent("old", "Review the tray", 50_000),
        { ...agent("child", "Read the spec", 1_000), parent: "old" },
        agent("mid", "Audit the stack", 20_000),
      ],
      [command("c-old", "bun run dev", 40_000), command("c-new", "bun run lint", 500)],
      [],
      true,
    );
    expect(items.map((item) => item.id)).toEqual(["c-new", "mid", "c-old", "old", "child"]);
  });
});
