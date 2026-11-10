// l10n-allow-file: test fixture subagent tasks, not shipped UI.
// The composer hat with one item (Leo, 2026-11-07: "when I click into it and it's only the one
// sub-agent, like the fact that it immediately brings me over to the sub-agent instead of expanding
// it is, like, ooh, I don't know"). One item heads the hat as several do: folded, the header names it,
// says what it does now and its time, and a click expands the hat in place; the line inside opens the
// subagent. The first click never navigates.
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

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
type TrayItem = import("../src/agent-session/acpmux/subagents/runningTray").TrayItem;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

const now = Date.now();
const agentItem = (agent: Partial<Subagent> & { id: string; task: string }): TrayItem => ({
  kind: "agent",
  id: agent.id,
  agent: { parent: null, name: agent.id, state: "running", startedAt: now - 9_000, ...agent },
  depth: 0,
});

async function hat(props: { items?: TrayItem[]; finished?: TrayItem[] }) {
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const opened: string[] = [];
  await act(async () =>
    root.render(
      createElement(SubagentTray, {
        items: props.items ?? [],
        finished: props.finished ?? [],
        working: true,
        waiting: new Set<string>(),
        onOpen: (id: string) => opened.push(id),
      }),
    ),
  );
  return {
    host,
    opened,
    head: () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head"),
    line: () => host.querySelector<HTMLButtonElement>(".acpmux-agent-line__button"),
    done: async () => act(async () => root.unmount()),
  };
}

describe("one item heads the hat", () => {
  test("a lone running subagent: the first click expands the hat, the line inside opens it", async () => {
    const view = await hat({
      items: [agentItem({ id: "a1", task: "Diagnose nightly lag, idle fleet", action: "Bash" })],
    });
    try {
      const head = view.head();
      expect(head).not.toBeNull();
      expect(head!.getAttribute("aria-expanded")).toBe("false");
      // Folded: its task and what it does now, on the header's one line.
      expect(head!.querySelector(".acpmux-running-tray__title")?.textContent).toBe("Diagnose nightly lag, idle fleet");
      expect(head!.querySelector(".acpmux-running-tray__latest")?.textContent).toBe("Running a command");
      await act(async () => head!.click());
      expect(view.opened).toEqual([]);
      expect(head!.getAttribute("aria-expanded")).toBe("true");
      const line = view.line();
      expect(line).not.toBeNull();
      // The line expands in place too; its detail's Open chat opens it (Leo, 2026-11-07).
      await act(async () => line!.click());
      expect(view.opened).toEqual([]);
      await act(async () => view.host.querySelector<HTMLButtonElement>("[data-line-detail] button")!.click());
      expect(view.opened).toEqual(["a1"]);
    } finally {
      await view.done();
    }
  });

  test("a lone finished subagent: folded, its task and a done mark with its time; a click expands", async () => {
    const view = await hat({
      finished: [agentItem({ id: "a1", task: "Diagnose nightly lag", state: "completed", endedAt: now - 1_000 })],
    });
    try {
      const head = view.head()!;
      expect(head.querySelector(".acpmux-running-tray__title")?.textContent).toBe("Diagnose nightly lag");
      const done = head.querySelector("[data-hat-done]");
      expect(done).not.toBeNull();
      expect(done!.textContent).toContain("8s");
      await act(async () => head.click());
      expect(view.opened).toEqual([]);
      expect(head.getAttribute("aria-expanded")).toBe("true");
    } finally {
      await view.done();
    }
  });

  test("a lone subagent acpmux retries says so at the row's end, with no stale step", async () => {
    const view = await hat({
      items: [
        agentItem({
          id: "a1",
          task: "Diagnose nightly lag",
          action: "Bash",
          state: "failed",
          retry: { attempt: 2, of: 4 },
        }),
      ],
    });
    try {
      const head = view.head()!;
      expect(head.querySelector(".acpmux-running-tray__time[data-lone]")?.textContent).toContain("Retrying (2/4)");
      expect(head.querySelector(".acpmux-running-tray__latest")).toBeNull();
    } finally {
      await view.done();
    }
  });

  test("a lone failed or waiting subagent, folded, says its state in its line's tone", async () => {
    // Review of #37671 (F2): folded, the header is all that says a lone line failed or waits.
    for (const [agent, waiting, status] of [
      [agentItem({ id: "a1", task: "Diagnose nightly lag", state: "failed", endedAt: now - 1_000 }), [], "failed"],
      [agentItem({ id: "a2", task: "Ask before pushing" }), ["a2"], "waiting"],
    ] as const) {
      resetTrayOpenMemory();
      const host = dom.window.document.getElementById("root")!;
      const root = createRoot(host);
      try {
        await act(async () =>
          root.render(
            createElement(SubagentTray, {
              items: [agent],
              working: true,
              waiting: new Set<string>(waiting),
              onOpen: () => {},
            }),
          ),
        );
        const end = host.querySelector(".acpmux-running-tray__time[data-lone]");
        expect(end?.getAttribute("data-status")).toBe(status);
        expect(end?.querySelector(".acpmux-running-tray__lone-state")?.textContent).not.toBe("");
      } finally {
        await act(async () => root.unmount());
      }
    }
  });

  test("a second item joining a folded hat changes only its words: same header, still folded, no list", async () => {
    // Leo, 2026-11-07, on the hat when a new command comes in: "we don't want it to, like, jitter. We
    // don't want it to be indecisive." A lone line used to turn into a header and a folding list.
    resetTrayOpenMemory();
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    const first = agentItem({ id: "a1", task: "Diagnose nightly lag", action: "Bash" });
    const draw = (items: TrayItem[]) =>
      act(async () =>
        root.render(
          createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} }),
        ),
      );
    try {
      await draw([first]);
      const head = host.querySelector(".acpmux-running-tray__head");
      expect(head).not.toBeNull();
      expect(host.querySelector(".acpmux-running-tray__fold")).toBeNull();
      await draw([first, agentItem({ id: "a2", task: "Watch the build", startedAt: now - 1_000 })]);
      expect(host.querySelector(".acpmux-running-tray__head")).toBe(head);
      expect(head!.getAttribute("aria-expanded")).toBe("false");
      expect(host.querySelector(".acpmux-running-tray__fold")).toBeNull();
      expect(host.querySelectorAll(".acpmux-running-tray__head").length).toBe(1);
    } finally {
      await act(async () => root.unmount());
    }
  });
});
