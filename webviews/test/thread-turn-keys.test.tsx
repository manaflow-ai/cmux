// Previous Turn and Next Turn (cx-f7c): the app's keys step the agent chat's transcript from one
// prompt to the next, as the thread minimap's ticks do with a click.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
// These tests drive the compact (Codex) rail; the default arm draws no minimap (layout.experiment.ts).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

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
  // Reduce Motion: a step lands at once (the browser test checks its curve).
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
// Wide enough for the minimap's usable gutter (ThreadMinimap RAIL_MIN_GUTTER).
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const TURNS = 12;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

test("Previous Turn and Next Turn step the transcript through its prompts", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const scrolled = async () => void scroller.dispatchEvent(new dom.window.Event("scroll"));
    // The app's Previous Turn and Next Turn (Ctrl-Opt-Up, Ctrl-Opt-Down) reach the page as bridge
    // commands, which raise these events, as the permission shortcuts' do.
    const step = (name: "previousTurn" | "nextTurn") =>
      act(async () => {
        dom.window.dispatchEvent(new dom.window.CustomEvent(`cmux-acpmux-${name}`));
        await scrolled();
      });
    /// The turn being read: the last whose prompt bubble is at or below 35 px under the viewport's
    /// top, where a step lands it (the thread pads its rows 16 px down); the first before any is.
    const reading = () => {
      const prompts = turns.filter((entry) => entry.kind === "user");
      let read = 0;
      prompts.forEach((entry, index) => {
        const node = dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${entry.id}"]`);
        const top = Number.parseFloat(node?.style.top ?? "") - 16; // less the thread's top padding
        if (Math.max(0, 16 + top - 35) <= scroller.scrollTop + 1) read = index;
      });
      return read;
    };
    await act(async () => {
      scroller.scrollTop = 0;
      await scrolled();
    });
    expect(reading()).toBe(0);
    await step("nextTurn");
    expect(reading()).toBe(1);
    await step("nextTurn");
    expect(reading()).toBe(2);
    await step("previousTurn");
    expect(reading()).toBe(1);
    // At the first prompt, Previous Turn stays.
    await step("previousTurn");
    expect(reading()).toBe(0);
    const before = scroller.scrollTop;
    await step("previousTurn");
    expect(scroller.scrollTop).toBe(before);
    expect(reading()).toBe(0);

    // A step counts from where the reader is, not from an earlier step's target: Next twice, then
    // the reader scrolls back to the top themselves, and Next goes to the second prompt.
    await step("nextTurn");
    await step("nextTurn");
    expect(reading()).toBe(2);
    await act(async () => {
      scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -400 }));
      scroller.scrollTop = 0;
      await scrolled();
    });
    expect(reading()).toBe(0);
    await step("nextTurn");
    expect(reading()).toBe(1);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Next Turn steps past a retried prompt beside acpmux's echo of it", async () => {
  // Turn 4's prompt is acpmux's echo (promptId p-dup); turn 5's is the pane's retried send of the
  // same prompt, back to sending (one promptId, two prompts). Next steps through every prompt.
  const dup = turns.map((entry) =>
    entry.id === "t4-user"
      ? { ...entry, promptId: "p-dup" }
      : entry.id === "t5-user"
        ? { ...entry, delivery: { state: "sending" as const, promptId: "p-dup", sessionId: "chat", sentAt: 0 } }
        : entry,
  );
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(dup, new Set())}
          sessionId="chat"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const scrolled = async () => void scroller.dispatchEvent(new dom.window.Event("scroll"));
    const prompts = dup.filter((entry) => entry.kind === "user");
    const reading = () => {
      let read = 0;
      prompts.forEach((entry, index) => {
        const node = dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${entry.id}"]`);
        const top = Number.parseFloat(node?.style.top ?? "") - 16;
        if (Math.max(0, 16 + top - 35) <= scroller.scrollTop + 1) read = index;
      });
      return read;
    };
    await act(async () => {
      scroller.scrollTop = 0;
      await scrolled();
    });
    // Steps in a row, each while the one before is still pending (its key is what it counts from).
    const seen: number[] = [];
    for (let n = 1; n < prompts.length; n += 1) {
      await act(async () => {
        dom.window.dispatchEvent(new dom.window.CustomEvent("cmux-acpmux-nextTurn"));
        await scrolled();
      });
      seen.push(reading());
    }
    // Each step lands on the next prompt through and past the pair, until the transcript's end stops
    // the scroll (the last prompts cannot reach the top of the view).
    expect(seen.slice(0, 7)).toEqual([1, 2, 3, 4, 5, 6, 7]);
  } finally {
    await act(async () => root.unmount());
  }
});
