// l10n-allow-file: test fixture subagent tasks, commands and transcripts, not shipped UI.
// The running tray's header expands in place OR opens the full Background tasks panel (Leo,
// 2026-11-03: "i feel like having a thing like this that can either expand OR open up to this sort of
// thing would be quite cool..."), and the panel reads as Claude Desktop's: "Running N" and
// "Finished N" headings, an agent's tasks under "N tasks", a failed agent's "Failed", and every row
// opening its own transcript with a way back.
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
  localStorage: dom.window.localStorage,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
replacements.CSS = { escape: (value: string) => value };
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
const { BackgroundTasksPanel, panelSections } =
  await import("../src/agent-session/acpmux/backgroundTasks/BackgroundTasksPanel");
type BackgroundGroup = import("../src/agent-session/acpmux/backgroundTasks/backgroundTasks").BackgroundGroup;
type AcpmuxRow = import("../src/agent-session/acpmux/model").AcpmuxRow;
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

async function tray(onOpenPanel?: () => void) {
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const items = trayItems([agent("a1", "Review the tray", 9_000), agent("a2", "Audit the stack", 3_000)], [], [], true);
  await act(async () =>
    root.render(
      createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {}, onOpenPanel }),
    ),
  );
  return {
    host,
    head: () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!,
    open: () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__open"),
    done: async () => act(async () => root.unmount()),
  };
}

describe("the running tray opens the Background tasks panel", () => {
  test("its panel button opens the panel; the header still expands in place", async () => {
    let opened = 0;
    const bar = await tray(() => opened++);
    try {
      const button = bar.open();
      expect(button).not.toBeNull();
      expect(button!.getAttribute("aria-label")).toBe("Open Background tasks");
      // A sibling of the header's own button (a button holds no button), over its slot.
      expect(bar.head().contains(button)).toBe(false);
      expect(bar.head().querySelector(".acpmux-running-tray__open-slot")).not.toBeNull();
      // The folded header keeps its names (#33104, #33364: the newest one, then +N more).
      expect(bar.head().querySelector(".acpmux-running-tray__title")?.textContent).toBe("Audit the stack");
      await act(async () => button!.click());
      expect(opened).toBe(1);
      expect(bar.head().getAttribute("aria-expanded")).toBe("false");
      await act(async () => bar.head().click());
      expect(bar.head().getAttribute("aria-expanded")).toBe("true");
      expect(opened).toBe(1);
    } finally {
      await bar.done();
    }
  });

  test("with no panel to open (Quick Chat), the header has no panel button", async () => {
    const bar = await tray();
    try {
      expect(bar.open()).toBeNull();
      expect(bar.head().querySelector(".acpmux-running-tray__open-slot")).toBeNull();
    } finally {
      await bar.done();
    }
  });
});

const group = (id: string, fields: Partial<BackgroundGroup>): BackgroundGroup => ({
  id: `agent:${id}`,
  kind: "agent",
  name: id,
  state: "done",
  startedAt: 1_000,
  endedAt: 51_000,
  running: [],
  finished: [],
  total: 0,
  failed: 0,
  agentId: id,
  ...fields,
});

const GROUPS: BackgroundGroup[] = [
  group("live", {
    name: "Link or route the unrouted asks",
    state: "running",
    endedAt: undefined,
    running: [
      {
        id: "t-run",
        kind: "tool",
        title: "Read NOW.md",
        state: "running",
        startedAt: 2_000,
        agentId: "live",
        rowId: "r-run",
      },
    ],
    finished: [
      {
        id: "t1",
        kind: "tool",
        title: "gh pr comment 2698",
        state: "done",
        startedAt: 1_000,
        endedAt: 14_000,
        agentId: "live",
        rowId: "r1",
      },
      {
        id: "t2",
        kind: "tool",
        title: "wt new leo-workspace",
        state: "failed",
        startedAt: 1_000,
        endedAt: 4_000,
        agentId: "live",
        rowId: "r2",
      },
    ],
    total: 3,
    failed: 1,
  }),
  group("review", { name: "Review asks sort change" }),
  group("broken", { name: "Make Codex reviews reliable", state: "failed" }),
];

const rowsOf = (id: string): AcpmuxRow[] => [
  { id: `${id}-ask`, version: 1, at: 1, kind: "user", text: `the ${id} agent's ask` },
  { id: `${id}-reply`, version: 1, at: 2, kind: "assistant", text: `the ${id} agent's reply` },
];
const VIEWS = { live: rowsOf("live"), review: rowsOf("review"), broken: rowsOf("broken") };

async function panel() {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(
      createElement(BackgroundTasksPanel, {
        groups: GROUPS,
        views: VIEWS,
        onClearFinished: () => {},
        onExpand: () => {},
        onClose: () => {},
      }),
    ),
  );
  const click = async (node: Element | null | undefined) => {
    expect(node).toBeTruthy();
    await act(async () => (node as HTMLElement).click());
  };
  return {
    host,
    click,
    title: () => host.querySelector(".acpmux-bg__title")?.textContent,
    back: () => host.querySelector<HTMLButtonElement>('.acpmux-bg__head button[aria-label="Back"]'),
    listHidden: () => host.querySelector<HTMLElement>(".acpmux-bg__list")!.hidden,
    transcript: () => host.querySelector(".acpmux-bg__transcript")?.textContent ?? "",
    done: async () => act(async () => root.unmount()),
  };
}

describe("the Background tasks panel", () => {
  test("splits its agents under Running and Finished, with counts, in the model's order", () => {
    const sections = panelSections(GROUPS);
    expect(sections.map((section) => [section.id, section.groups.map((entry) => entry.id)])).toEqual([
      ["running", ["agent:live"]],
      ["finished", ["agent:review", "agent:broken"]],
    ]);
    // A group whose own agent ended but whose nested agent runs is a running one.
    const nested = group("parent", {
      running: [{ id: "n", kind: "agent", title: "Nested", state: "running", startedAt: 1_000, agentId: "n" }],
      total: 1,
    });
    expect(panelSections([nested]).map((section) => section.id)).toEqual(["running"]);
    // Nothing ended: no Finished heading.
    expect(panelSections([GROUPS[0]!]).map((section) => section.id)).toEqual(["running"]);
  });

  test("renders the headings, an agent's N tasks fold, durations and Failed", async () => {
    const view = await panel();
    try {
      const heads = [...view.host.querySelectorAll(".acpmux-bg__section-head")].map((node) => node.textContent);
      expect(heads).toEqual(["Running1", "Finished2"]);
      const live = view.host.querySelector('[data-group="agent:live"]')!;
      expect(live.querySelector(".acpmux-bg__fold")?.textContent).toBe("3 tasks, 1 failed");
      const review = view.host.querySelector('[data-group="agent:review"]')!;
      expect(review.querySelector(".acpmux-bg__agent .acpmux-bg__time")?.textContent).toBe("50s");
      const broken = view.host.querySelector('[data-group="agent:broken"]')!;
      const state = broken.querySelector(".acpmux-bg__agent .acpmux-bg__time");
      expect(state?.textContent).toBe("Failed");
      expect(state?.classList.contains("acpmux-bg__failed")).toBe(true);
      // A heading folds its agents.
      await view.click(view.host.querySelector('[data-section="finished"] .acpmux-bg__section-head'));
      expect(view.host.querySelector('[data-group="agent:review"]')).toBeNull();
      expect(
        view.host.querySelector('[data-section="finished"] .acpmux-bg__section-head')?.getAttribute("aria-expanded"),
      ).toBe("false");
    } finally {
      await view.done();
    }
  });

  test("an agent's row and each of its tasks open that agent's transcript, and Back returns", async () => {
    const view = await panel();
    try {
      // A finished agent, from the Finished heading.
      await view.click(view.host.querySelector('[data-group="agent:review"] .acpmux-bg__name'));
      expect(view.title()).toBe("Review asks sort change");
      expect(view.listHidden()).toBe(true);
      expect(view.transcript()).toContain("the review agent's reply");
      await view.click(view.back());
      expect(view.title()).toBe("Background tasks");
      expect(view.listHidden()).toBe(false);
      // A running agent's task: its own agent's transcript.
      await view.click(view.host.querySelector('[data-group="agent:live"] .acpmux-bg__task .acpmux-bg__task-open'));
      expect(view.title()).toBe("Link or route the unrouted asks");
      expect(view.transcript()).toContain("the live agent's reply");
      await view.click(view.back());
      expect(view.listHidden()).toBe(false);
      // The list is as it was: the running agent's tasks still open.
      expect(view.host.querySelector('[data-group="agent:live"] .acpmux-bg__tasks')).not.toBeNull();
    } finally {
      await view.done();
    }
  });
});

// Leo, 2026-11-03: "it should be opening up on the right pane as a tab instead of this". The panel
// opens as a tab in the chat's right column through the subagent pane path, under a reserved id.
describe("Background tasks opens as a tab in the right column", () => {
  test("it asks the app for the chat's right-column tab, named Background tasks", async () => {
    const { BACKGROUND_PANE, isBackgroundPane, openBackgroundPane } =
      await import("../src/agent-session/acpmux/backgroundTasks/backgroundPane");
    const { revealedSubagent } = await import("../src/agent-session/acpmux/subagents/subagentPanes");
    const calls: [string, Record<string, unknown>][] = [];
    const opened = await openBackgroundPane(async (method, params) => {
      calls.push([method, params]);
      return { opened: true };
    }, "Background tasks");
    expect(opened).toBe(true);
    expect(calls).toEqual([
      ["chat.subagentPane", { subagent: BACKGROUND_PANE, focus: true, title: "Background tasks" }],
    ]);
    // The tab's page reads the app's `subagent:<id>` reveal as this panel, never as a subagent.
    expect(isBackgroundPane(revealedSubagent(`subagent:${BACKGROUND_PANE}`))).toBe(true);
    expect(isBackgroundPane(revealedSubagent("subagent:toolu_01"))).toBe(false);
    // A host that opens no tab answers false (or throws), and the chat's own column takes the panel.
    expect(await openBackgroundPane(async () => ({ opened: false }), "Background tasks")).toBe(false);
    expect(await openBackgroundPane(async () => Promise.reject(new Error("no host")), "Background tasks")).toBe(false);
  });

  test("in its own tab the header keeps Clear finished, without Expand or Close", async () => {
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    await act(async () =>
      root.render(createElement(BackgroundTasksPanel, { groups: GROUPS, views: VIEWS, onClearFinished: () => {} })),
    );
    const labels = [...host.querySelectorAll(".acpmux-bg__head button")].map((b) => b.getAttribute("aria-label"));
    expect(labels).not.toContain("Expand");
    expect(labels).not.toContain("Close");
    expect(host.querySelector(".acpmux-bg__title")?.textContent).toBe("Background tasks");
    await act(async () => root.unmount());
  });
});
