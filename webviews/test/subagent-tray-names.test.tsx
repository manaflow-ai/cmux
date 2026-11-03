// l10n-allow-file: test fixture subagent tasks and commands, not shipped UI.
// The running tray's folded header names what runs (Leo, 2026-11-03: "the "running" bar above the
// composer is currently no longer usable bc it doesn't display much", on a bar that read only
// "1 subagent running · 1 command 4s"). Folded, it reads as Claude Code's running-tasks list does:
// the subagent's task and the command's description (its short command when it has none), the
// newest one, then a count of the rest: one name that fits beats two cut ones (Leo, 2026-11-03, on a
// bar whose two names were both cut). Open, the lines list them newest first, as the folded bar
// names them ("this previews one of the latest but it doesn't show in latest it shows in oldest
// order"), and the header keeps its counts.
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
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

async function head(agents: Subagent[], commands: BackgroundCommand[], arm?: string) {
  resetTrayOpenMemory();
  scope.cmuxExperiments = arm ? { "subagent-tray-fold-head": arm } : undefined;
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
    time: () => button.querySelector(".acpmux-running-tray__time")?.textContent ?? "",
    more: () => button.querySelector(".acpmux-running-tray__more")?.textContent ?? "",
    done: async () => {
      await act(async () => root.unmount());
      scope.cmuxExperiments = undefined;
    },
  };
}

describe("the folded running bar names what runs", () => {
  test("one subagent and one command: the newest one's name, then a count of the other", async () => {
    const bar = await head(
      [agent("a1", "Explore how the daemon updates itself", 4_000)],
      [command("c1", "cd ~/app && bun test --watch", 2_000, "Watch the tests")],
      "one",
    );
    try {
      expect(bar.button.getAttribute("aria-expanded")).toBe("false");
      expect(bar.title()).toBe("Watch the tests");
      expect(bar.more()).toBe("+1 more");
      // Open, the lines name them and the header goes back to its counts.
      await act(async () => bar.button.click());
      expect(bar.title()).toBe("1 subagent running · 1 command");
    } finally {
      await bar.done();
    }
  });

  test("a command with no description is named by its short command", async () => {
    const bar = await head(
      [agent("a1", "Review the tray", 9_000)],
      [command("c1", "cd ~/Projects/app && bun run dev", 1_000)],
      "one",
    );
    try {
      expect(bar.title()).toBe("bun run dev");
    } finally {
      await bar.done();
    }
  });

  test("five running: the newest one by name, then a count of the rest", async () => {
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
      "one",
    );
    try {
      expect(bar.title()).toBe("Lint the web");
      expect(bar.more()).toBe("+4 more");
    } finally {
      await bar.done();
    }
  });
});

// Leo, 2026-11-03: "you can split up commands/waits/bg tasks/subagents/maybe agent sessions you
// expect something from ... so you can fit that all in counts of stuff and maybe times all in one
// line like a \ b \ c or a | b| c or a / b / c". By kind is the default arm.
describe("the folded running bar counts what runs by kind, with times", () => {
  test("each kind's count and its oldest one's time, on one line, in kind order", async () => {
    const bar = await head(
      [agent("a1", "Review the tray", 245_000), agent("a2", "Review the fold", 30_000)],
      [
        command("c1", "cd ~/app && bun run dev", 725_000, "Run the dev server"),
        command("c2", "glaeda-gh wait run 123 --sha abc", 40_000, "Wait for CI"),
        command("c3", "sleep 30 && gh pr view 12", 12_000),
        command("c4", "acpmux send tests 'run the suite'", 9_000),
        command("c5", "bun run lint", 5_000, "Lint the web"),
      ],
    );
    try {
      expect(bar.title()).toBe("2 subagents 4m 5s / 1 message 9s / 2 waits 40s / 1 server 12m 5s / 1 command 5s");
      // The kinds carry the times, so the header's one time and +N are not drawn.
      expect(bar.time()).toBe("");
      expect(bar.more()).toBe("");
      // Open, the header goes back to its counts.
      await act(async () => bar.button.click());
      expect(bar.title()).toBe("2 subagents running · 5 commands");
    } finally {
      await bar.done();
    }
  });

  test("only kinds that run are named", async () => {
    const bar = await head(
      [],
      [command("c1", "gh run watch 991", 3_000), command("c2", "tail -f /tmp/build.log", 70_000, "Follow the build")],
    );
    try {
      expect(bar.title()).toBe("2 waits 1m 10s");
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
