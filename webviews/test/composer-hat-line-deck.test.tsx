// l10n-allow-file: test fixture subagent names, commands and chats, not shipped UI.
// The one-line composer hat's marks and hide eye (hatLine.experiment.ts; Leo, 2026-11-20: "thumb through
// them like a Rolodex or whatever at the top ... there's a slight pop and something ... perhaps the text
// itself maybe changes like on the top of the composer hat"). Every arm but `words` draws one mark per
// running line on the line itself: pointing at one names its line, leaving gives the sentence back, a
// click opens it and leaves the hat folded; the hide control is a flush eye at the line's end.
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

trackReactScheduler();
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
  scope.cmuxExperiments = { "composer-hat-line-deck": arm, "subagent-tray-fold-head": "line" };
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

describe("the one-line hat's marks", () => {
  test("trail draws the marks after the sentence and the eye at the line's end", async () => {
    const { host, marks, done } = await mount("trail", { onTuck: () => {} });
    try {
      expect(marks().length).toBe(3);
      const deck = host.querySelector(".acpmux-hat-deck")!;
      expect(deck.getAttribute("data-at")).toBe("trail");
      const title = host.querySelector(".acpmux-running-tray__title")!;
      expect(title.compareDocumentPosition(deck) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
      expect(host.querySelector('.acpmux-hat-hide[data-at="line"]')).not.toBeNull();
      expect(host.querySelector(".acpmux-running-tray__tuck")).toBeNull();
    } finally {
      await done();
    }
  });

  test("lead draws the marks before the sentence", async () => {
    const { host, done } = await mount("lead", { onTuck: () => {} });
    try {
      const deck = host.querySelector(".acpmux-hat-deck")!;
      expect(deck.getAttribute("data-at")).toBe("lead");
      const title = host.querySelector(".acpmux-running-tray__title")!;
      expect(title.compareDocumentPosition(deck) & dom.window.Node.DOCUMENT_POSITION_PRECEDING).toBeTruthy();
    } finally {
      await done();
    }
  });

  test("cards draws the fanned deck", async () => {
    const { host, done } = await mount("cards");
    try {
      expect(host.querySelector(".acpmux-hat-deck")?.getAttribute("data-look")).toBe("cards");
    } finally {
      await done();
    }
  });

  test("pointing at a mark names its line and leaving gives the sentence back", async () => {
    const { host, title, marks, enter, leave, done } = await mount("trail");
    try {
      const sentence = title();
      await enter(marks()[2]!);
      expect(marks()[2]!.hasAttribute("data-peeked")).toBe(true);
      expect(title()).toContain("Port the history page");
      await leave(marks()[2]!, host.querySelector(".acpmux-running-tray__head")!);
      await leave(host.querySelector(".acpmux-hat-deck")!, dom.window.document.body);
      expect(title()).toBe(sentence);
    } finally {
      await done();
    }
  });

  test("a click on a mark opens its line and leaves the hat folded", async () => {
    const opened: string[] = [];
    const { head, marks, done } = await mount("trail", {
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

  test("the eye hides the hat", async () => {
    let tucked = 0;
    const { host, done } = await mount("trail", { onTuck: () => (tucked += 1) });
    try {
      await act(async () => host.querySelector<HTMLButtonElement>('.acpmux-hat-hide[data-at="line"]')!.click());
      expect(tucked).toBe(1);
    } finally {
      await done();
    }
  });

  test("words keeps the plain line and its top-edge tab", async () => {
    const { host, done } = await mount("words", { onTuck: () => {} });
    try {
      expect(host.querySelector(".acpmux-hat-deck")).toBeNull();
      expect(host.querySelector(".acpmux-hat-hide")).toBeNull();
      expect(host.querySelector(".acpmux-running-tray__tuck")).not.toBeNull();
    } finally {
      await done();
    }
  });
});
