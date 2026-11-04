// l10n-allow-file: test fixture todo items and commands, not shipped UI.
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
const { liveTurnPlan } = await import("../src/agent-session/acpmux/conversation/turns");
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;
type AcpmuxRow = import("../src/agent-session/acpmux/model").AcpmuxRow;
type AcpmuxPlanEntry = import("../src/agent-session/acpmux/model").AcpmuxPlanEntry;

// The running turn's todo list is in the composer's hat (Leo, 2026-11-03: "we said earlier the
// composer hat is kinda ok?"): folded, "2 of 5 · <the step at work>" before what runs; opened, the
// checklist over the lines. Settings > Agent Chat > Pin Task List in Chat pins it in the transcript
// instead (App.tsx `planInHat`).
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

const now = Date.now();
const plan: AcpmuxPlanEntry[] = [
  { content: "Read the tray", status: "completed" },
  { content: "Move the plan", status: "completed" },
  { content: "Run the tray tests", status: "in_progress" },
  { content: "Compile the app", status: "pending" },
  { content: "Update the spec", status: "pending" },
];
const command = (id: string, line: string, startedAgo: number, description: string): BackgroundCommand => ({
  id,
  command: line,
  state: "running",
  startedAt: now - startedAgo,
  description,
});

async function hat(commands: BackgroundCommand[], entries: readonly AcpmuxPlanEntry[] | undefined) {
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const items = trayItems([], commands, [], true);
  await act(async () =>
    root.render(
      createElement(SubagentTray, {
        items,
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
        plan: entries,
      }),
    ),
  );
  const button = () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head");
  return {
    host,
    button,
    title: () => button()?.querySelector(".acpmux-running-tray__title")?.textContent,
    done: async () => act(async () => root.unmount()),
  };
}

describe("the composer hat shows the running turn's plan", () => {
  test("a plan alone: the hat reads its progress and the step at work, and opens the checklist", async () => {
    const bar = await hat([], plan);
    try {
      expect(bar.title()).toBe("2 of 5 · Run the tray tests");
      expect(bar.host.querySelector(".cv-plan")).toBeNull();
      await act(async () => bar.button()!.click());
      const steps = [...bar.host.querySelectorAll(".acpmux-running-tray .cv-plan__item")];
      expect(steps.map((step) => step.getAttribute("data-status"))).toEqual(plan.map((entry) => entry.status));
    } finally {
      await bar.done();
    }
  });

  test("with three background commands: the plan leads, then the newest command and a count", async () => {
    const bar = await hat(
      [
        command("c1", "bun run dev", 90_000, "Start the dev server"),
        command("c2", "cmux-ci compile-check --app", 60_000, "Compile the app on the fleet"),
        command("c3", "bun test test/subagent-tray.test.tsx", 30_000, "Watch the tests"),
      ],
      plan,
    );
    try {
      expect(bar.title()?.startsWith("2 of 5 · Run the tray tests · Watch the tests")).toBe(true);
      await act(async () => bar.button()!.click());
      expect(bar.host.querySelectorAll(".acpmux-running-tray .cv-plan__item").length).toBe(5);
      expect(bar.host.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length).toBe(3);
    } finally {
      await bar.done();
    }
  });

  test("an all-done list reads only its progress", async () => {
    const bar = await hat(
      [],
      plan.map((entry) => ({ ...entry, status: "completed" as const })),
    );
    try {
      expect(bar.title()).toBe("5 of 5");
    } finally {
      await bar.done();
    }
  });

  test("the hat takes only the running turn's list, never one whose turn ended", () => {
    const row = (id: string, fields: Partial<AcpmuxRow>) =>
      ({ id, version: 1, at: now, kind: "plan", ...fields }) as AcpmuxRow;
    const ended = row("p1", { plan, turnEnded: true });
    const live = row("p2", { plan });
    expect(liveTurnPlan([ended])).toBeUndefined();
    expect(liveTurnPlan([ended, live])).toBe(live);
    expect(liveTurnPlan([row("p3", { plan: [] })])).toBeUndefined();
  });
});
