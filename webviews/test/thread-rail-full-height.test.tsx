// The prompt rail's vertical placement. Its box is centered in the transcript's view (model.ts railTop)
// and holds the ticks it draws. Prompts not held yet (the snapshot's `promptCount`, before the prompt
// index answers or on a daemon without one) reserve no empty rows above the held ticks: that pushed the
// held ticks to the box's foot, just above the composer (Leo, 2026-11-01: "what a stupid f***ing choice
// to put the f***ing scroll rail at the bottom???"). The prompt index gives every prompt its tick, so
// the rail is full height once it answers (Leo, 2026-11-01: "i also want the left scroll rail to be
// starting off to its max height if there truly are that many prompts in the chat").
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div><div id=dock></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
/// Every ResizeObserver the transcript makes, so a test can say a box changed size.
const observers: { callback: ResizeObserverCallback; self: ResizeObserver }[] = [];
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(callback: ResizeObserverCallback) {
      observers.push({ callback, self: this as unknown as ResizeObserver });
    }
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

// jsdom has no layout: a 700 px view, a pane 1040 px wide, and a bottom stack `stack` px tall laid over
// the view's foot.
const VIEWPORT = 700;
const PANE = 1040;
const stack = 120;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => PANE });
const rect = (top: number, height: number) =>
  ({ top, bottom: top + height, height, left: 0, right: PANE, width: PANE, x: 0, y: top }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  if (this.id === "dock") return rect(VIEWPORT - stack, stack);
  if (this.classList.contains("acpmux-composer-box")) return rect(VIEWPORT - stack, stack);
  if (this.classList.contains("acpmux-scroll")) return rect(0, VIEWPORT);
  return rect(0, 0);
};
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
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

/// The rail's box and where its latest tick draws, in px down the view.
const rail = () => {
  const nav = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
  const list = nav.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const ticks = nav.querySelectorAll(".acpmux-minimap__entry, .acpmux-minimap__gap");
  const rows = [...ticks].reduce(
    (sum, node) =>
      sum +
      (node.classList.contains("acpmux-minimap__gap") ? Number.parseFloat((node as HTMLElement).style.height) / 10 : 1),
    0,
  );
  const top = Number.parseFloat(nav.style.top);
  const lead = Number.parseFloat(list.style.marginTop || "0");
  return {
    top,
    lead,
    height: Number.parseFloat(nav.style.height),
    latest: top + lead + (rows - 1) * 10 - list.scrollTop,
  };
};

const centered = (height: number) => Math.round((VIEWPORT - height) / 2);

test("held ticks sit centered in the view, never stacked at the box's foot, while older prompts are not held", async () => {
  const all = chat(45);
  const prompts = all.filter((entry) => entry.kind === "user");
  const held = all.slice(all.indexOf(prompts[33]!));
  const earlier = prompts.slice(0, 33).map((entry) => ({ ...entry }));
  const root = createRoot(document.getElementById("root")!);
  const dock = document.getElementById("dock")!;
  const render = (props: { earlier?: AcpmuxRow[]; promptCount?: number }) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(held, new Set())}
          {...props}
          sessionId="rail-full"
          dock={dock}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    // The first frame: twelve prompts held, the summary says forty-five.
    await render({ promptCount: 45 });
    const open = rail();
    // The box holds the twelve ticks (the 320 px floor), centered: no empty rows above them.
    expect(open.lead).toBe(0);
    expect(open.height).toBe(320);
    expect(open.top).toBe(centered(320));
    // The latest tick draws in the box's top half's reach, nowhere near the view's foot.
    expect(open.latest).toBe(open.top + 11 * 10);
    expect(open.latest).toBeLessThan(VIEWPORT - stack - 100);
    // The index answers: every prompt has its tick, and the taller box is still centered.
    await render({ earlier });
    const full = rail();
    expect(full.lead).toBe(0);
    expect(full.height).toBe(450);
    expect(full.top).toBe(centered(450));
  } finally {
    await act(async () => root.unmount());
  }
});

test("without a count the rail grows as prompts arrive, as before", async () => {
  const all = chat(45);
  const prompts = all.filter((entry) => entry.kind === "user");
  const held = all.slice(all.indexOf(prompts[33]!));
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(held, new Set())}
          sessionId="rail-grow"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    // Twelve prompts: the rail's 320 px floor, centered.
    expect(rail().height).toBe(320);
    expect(rail().top).toBe(centered(320));
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat with more prompts than the rail holds keeps its latest tick at the box's end once the index arrives", async () => {
  const all = chat(80);
  const prompts = all.filter((entry) => entry.kind === "user");
  const held = all.slice(all.indexOf(prompts[68]!));
  const earlier = prompts.slice(0, 68).map((entry) => ({ ...entry }));
  const root = createRoot(document.getElementById("root")!);
  const dock = document.getElementById("dock")!;
  const render = (props: { earlier?: AcpmuxRow[]; promptCount?: number }) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(held, new Set())}
          {...props}
          sessionId="rail-over"
          dock={dock}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    await render({ promptCount: 80 });
    // Twelve held: the 320 px floor, centered, with no empty rows above the ticks.
    expect(rail().lead).toBe(0);
    expect(rail().height).toBe(320);
    await render({ earlier });
    const open = rail();
    // Taller than the room: the rail fills it, and the latest tick ends at its bottom.
    expect(open.height).toBeLessThan(800);
    expect(open.latest + 10).toBe(open.top + open.height);
  } finally {
    await act(async () => root.unmount());
  }
});
