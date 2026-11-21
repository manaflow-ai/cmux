// l10n-allow-file: test fixture subagent tasks and commands, not shipped UI.
// The composer hat's marks beside the composer (subagents/HatRail.tsx, hatSide.experiment.ts). Leo,
// 2026-11-21, on the Rolodex hat: "this is uncomfortably tight. didn't we say we wanted to move these
// to the side or smth?". In each side arm the marks render in the rail (or on the composer's bottom
// line), hovering or focusing one names its line, a click opens that line through the hat's own open
// path (SubagentTray.tsx `openHatMark`), and the keyboard reaches and steps through every mark.
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
const { HatRail } = await import("../src/agent-session/acpmux/subagents/HatRail");
type BackgroundCommand = import("../src/agent-session/acpmux/session-info/processes").BackgroundCommand;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
type HatSide = import("../src/agent-session/acpmux/subagents/hatSide.experiment").HatSide;


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

async function rail(side: HatSide, agents: Subagent[], commands: BackgroundCommand[]) {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const opened: string[] = [];
  const openedCommands: string[] = [];
  const lists: boolean[] = [];
  const items = trayItems(agents, commands, [], true);
  await act(async () =>
    root.render(
      createElement(HatRail, {
        side,
        items,
        waiting: new Set<string>(),
        listOpen: false,
        onOpen: (id: string) => opened.push(id),
        onOpenCommand: (one: BackgroundCommand) => openedCommands.push(one.id),
        onList: (open: boolean) => lists.push(open),
      }),
    ),
  );
  const toolbar = () => host.querySelector<HTMLElement>(".acpmux-hat-rail");
  const marks = () => [...host.querySelectorAll<HTMLButtonElement>("button[data-rolodex-key]")];
  const label = () => host.querySelector(".acpmux-hat-rail__label")?.textContent;
  const hover = async (node: Element) =>
    act(async () => {
      node.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: toolbar() }));
    });
  const leave = async (node: Element) =>
    act(async () => {
      node.dispatchEvent(
        new dom.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: dom.window.document.body }),
      );
    });
  return {
    host,
    toolbar,
    marks,
    label,
    hover,
    leave,
    opened,
    openedCommands,
    lists,
    done: async () => act(async () => root.unmount()),
  };
}

const SIDES: readonly HatSide[] = ["right-rail", "left-rail", "bottom-line"];

describe("the composer hat's marks beside the composer", () => {
  for (const side of SIDES) {
    describe(side, () => {
      test("the marks stand in the rail, longest-running first, then the commands' one mark", async () => {
        const bar = await rail(
          side,
          [agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000)],
          [command("c1", "bun run dev", 1_000, "Dev server")],
        );
        try {
          expect(bar.toolbar()?.getAttribute("data-side")).toBe(side);
          expect(bar.toolbar()?.getAttribute("aria-orientation")).toBe(
            side === "bottom-line" ? "horizontal" : "vertical",
          );
          expect(bar.marks().map((mark) => mark.dataset.rolodexKey)).toEqual(["agent:a1", "agent:a2", "commands"]);
          expect(bar.host.querySelector(".acpmux-hat-rail__list")).toBeTruthy();
        } finally {
          await bar.done();
        }
      });

      test("hovering a mark lifts it and names its line and what it does now; leaving clears it", async () => {
        const bar = await rail(
          side,
          [agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000, "Read SubagentTray.tsx")],
          [],
        );
        try {
          expect(bar.label()).toBeUndefined();
          const second = bar.marks()[1];
          await bar.hover(second);
          expect(second.hasAttribute("data-peeked")).toBe(true);
          expect(bar.label()).toContain("Audit the stack");
          expect(bar.label()).toContain("SubagentTray.tsx");
          expect(second.getAttribute("aria-label")).toContain("Audit the stack");
          await bar.leave(bar.toolbar()!);
          expect(bar.label()).toBeUndefined();
        } finally {
          await bar.done();
        }
      });

      test("a click opens that line through the hat's open path", async () => {
        const bar = await rail(
          side,
          [agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000)],
          [command("c1", "bun run dev", 1_000, "Dev server")],
        );
        try {
          await act(async () => bar.marks()[1].click());
          expect(bar.opened).toEqual(["a2"]);
          await act(async () => bar.marks()[2].click());
          expect(bar.openedCommands).toEqual(["c1"]);
          expect(bar.lists).toEqual([]);
          // The list control shows the hat's full list.
          await act(async () => bar.host.querySelector<HTMLButtonElement>(".acpmux-hat-rail__list")!.click());
          expect(bar.lists).toEqual([true]);
        } finally {
          await bar.done();
        }
      });

      test("two commands share one mark, which opens the list rather than one terminal", async () => {
        const bar = await rail(
          side,
          [agent("a1", "Review the tray", 50_000)],
          [command("c1", "bun run dev", 9_000, "Dev server"), command("c2", "bun run lint", 2_000, "Lint the web")],
        );
        try {
          const shared = bar.marks().find((mark) => mark.dataset.rolodexKey === "commands")!;
          await bar.hover(shared);
          expect(bar.label()).toContain("Dev server");
          expect(bar.label()).toContain("Lint the web");
          await act(async () => shared.click());
          expect(bar.openedCommands).toEqual([]);
          expect(bar.lists).toEqual([true]);
        } finally {
          await bar.done();
        }
      });

      test("the keyboard reaches each mark: focus names it, the arrows step along the rail", async () => {
        const bar = await rail(
          side,
          [agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000)],
          [],
        );
        try {
          const [first, second] = bar.marks();
          expect(first.tagName).toBe("BUTTON");
          await act(async () => first.focus());
          expect(dom.window.document.activeElement).toBe(first);
          expect(bar.label()).toContain("Review the tray");
          const forward = side === "bottom-line" ? "ArrowRight" : "ArrowDown";
          const back = side === "bottom-line" ? "ArrowLeft" : "ArrowUp";
          await act(async () => {
            first.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: forward, bubbles: true }));
          });
          expect(dom.window.document.activeElement).toBe(second);
          expect(bar.label()).toContain("Audit the stack");
          await act(async () => {
            second.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: back, bubbles: true }));
          });
          expect(dom.window.document.activeElement).toBe(first);
          // Enter on a focused mark is its click: it opens the line.
          await act(async () => first.click());
          expect(bar.opened).toEqual(["a1"]);
        } finally {
          await bar.done();
        }
      });
    });
  }
});
