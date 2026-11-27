// l10n-allow-file: test fixture subagent names, commands and chats, not shipped UI.
// The composer hat's top bar (hatHeader.experiment.ts, HatHeadDeck.tsx; Leo, 2026-11-20: "thumb through
// them like a Rolodex or whatever at the top ... you can click into them and be able to open up that
// sub-agent ... where would the hide button be?"). The `strip` and `cards` arms draw one mark per running
// line: pointing at one names its line in the header, leaving gives the summary back, a click opens it
// and never folds or unfolds the hat. The `cards` deck thumbs on the wheel. The `eye`, `pill` and `bar`
// arms move the hide control and drop today's top-edge tab. `today` keeps today's header.
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
  // The arm, as the gallery's stage frame pins it (experiments/experiment.ts, source 1); each test sets it.
  cmuxExperiments: {},
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
  harness: "codex",
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

async function mount(arm: string, props: Record<string, unknown> = {}) {
  scope.cmuxExperiments = { "composer-hat-header": arm };
  resetTrayOpenMemory();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(
      createElement(SubagentTray, { items, working: false, waiting: new Set<string>(), onOpen: () => {}, ...props }),
    ),
  );
  const head = () => host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
  const title = () => host.querySelector(".acpmux-running-tray__title")?.textContent ?? "";
  const marks = () => [...host.querySelectorAll<HTMLElement>(".acpmux-hat-deck__mark")];
  // React's enter and leave come from pointerover and pointerout with the node the pointer came from.
  const enter = async (node: Element, from: Element | null = null) =>
    act(async () => {
      // As a real pointer does: out of the last element, then over the next. React derives enter and
      // leave between two of its own nodes from the pointerout alone, and ignores a pointerover whose
      // relatedTarget it manages.
      if (from) from.dispatchEvent(new dom.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: node }));
      node.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: from }));
    });
  const leave = async (node: Element, to: Element) =>
    act(async () => {
      node.dispatchEvent(new dom.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: to }));
    });
  return { host, head, title, marks, enter, leave, done: async () => act(async () => root.unmount()) };
}

describe("the composer hat's top bar", () => {
  test("today keeps today's header and its top-edge tuck", async () => {
    const { host, done } = await mount("today", { onTuck: () => {} });
    try {
      expect(host.querySelector(".acpmux-hat-deck")).toBeNull();
      expect(host.querySelector(".acpmux-running-tray__tuck")).not.toBeNull();
      expect(host.querySelector(".acpmux-hat-hide, .acpmux-hat-hide-bar")).toBeNull();
    } finally {
      await done();
    }
  });

  test("the strip names a pointed-at line, thumbs on to the next, and gives the summary back", async () => {
    const { host, title, marks, enter, leave, done } = await mount("strip");
    try {
      expect(marks().length).toBe(3);
      const summary = title();
      await enter(marks()[0]!);
      expect(marks()[0]!.hasAttribute("data-peeked")).toBe(true);
      expect(title()).toContain("Review the fold motion");
      // Straight on to the next mark: no gap where the summary comes back.
      await enter(marks()[2]!, marks()[0]!);
      expect(marks()[0]!.hasAttribute("data-peeked")).toBe(false);
      expect(title()).toContain("Port the history page");
      expect(host.querySelector(".acpmux-running-tray__latest")?.textContent).toContain("Read HistoryPage.tsx");
      await leave(marks()[2]!, host.querySelector(".acpmux-running-tray__head")!);
      await leave(host.querySelector(".acpmux-hat-deck")!, dom.window.document.body);
      expect(marks().some((mark) => mark.hasAttribute("data-peeked"))).toBe(false);
      expect(title()).toBe(summary);
    } finally {
      await done();
    }
  });

  test("a click on a mark opens its line as the line does and leaves the hat folded", async () => {
    const opened: string[] = [];
    const { head, marks, done } = await mount("strip", {
      onOpen: (id: string) => opened.push(`agent:${id}`),
      onOpenCommand: (entry: BackgroundCommand) => opened.push(`command:${entry.id}`),
      onOpenSession: (id: string) => opened.push(`chat:${id}`),
    });
    try {
      for (const mark of marks()) await act(async () => mark.click());
      expect(opened).toEqual(["agent:agent-reviewer", "command:s/1", "chat:c1"]);
      expect(head().getAttribute("aria-expanded")).toBe("false");
    } finally {
      await done();
    }
  });

  test("a mark with nothing to open opens the hat on its line instead", async () => {
    const { head, marks, done } = await mount("strip", { canOpenTerminal: false, onOpenCommand: () => {} });
    try {
      await act(async () => marks()[1]!.click());
      expect(head().getAttribute("aria-expanded")).toBe("true");
    } finally {
      await done();
    }
  });

  test("the cards deck thumbs card to card on the wheel", async () => {
    const { host, title, marks, done } = await mount("cards");
    try {
      expect(host.querySelector(".acpmux-hat-deck")?.getAttribute("data-look")).toBe("cards");
      const deck = host.querySelector(".acpmux-hat-deck")!;
      const wheel = async (deltaY: number) =>
        act(async () => {
          deck.dispatchEvent(new dom.window.WheelEvent("wheel", { bubbles: true, deltaY }));
        });
      // A small delta is not a card yet; enough of them is one.
      await wheel(10);
      expect(marks().some((mark) => mark.hasAttribute("data-peeked"))).toBe(false);
      await wheel(20);
      expect(marks()[1]!.hasAttribute("data-peeked")).toBe(true);
      await wheel(30);
      expect(marks()[2]!.hasAttribute("data-peeked")).toBe(true);
      expect(title()).toContain("Port the history page");
      // It wraps back to the front card.
      await wheel(30);
      expect(marks()[0]!.hasAttribute("data-peeked")).toBe(true);
    } finally {
      await done();
    }
  });

  for (const arm of ["eye", "pill", "bar"] as const)
    test(`the ${arm} arm moves the hide control and drops the top-edge tab`, async () => {
      let tucked = 0;
      const { host, marks, done } = await mount(arm, { onTuck: () => (tucked += 1) });
      try {
        expect(host.querySelector(".acpmux-running-tray")?.getAttribute("data-hide-at")).toBe(arm);
        expect(host.querySelector(".acpmux-running-tray__tuck")).toBeNull();
        // The strip comes with it.
        expect(marks().length).toBe(3);
        const hide = host.querySelector<HTMLButtonElement>(arm === "bar" ? ".acpmux-hat-hide-bar" : ".acpmux-hat-hide");
        expect(hide).not.toBeNull();
        expect(hide!.getAttribute("aria-label")).toBeTruthy();
        await act(async () => hide!.click());
        expect(tucked).toBe(1);
      } finally {
        await done();
      }
    });
});
