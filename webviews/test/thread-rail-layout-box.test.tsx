// The prompt rail's own layout box (Leo, 2026-11-01: "the left side scroll rail needs to not really get
// affected by most other layout things it shouldn't really shift much at all"). Its top, height and
// inset read only the transcript's view and the prompt count: a composer that grows over the view, a
// tray that opens in the bottom stack, or a pane that widens (the sidebar toggle) leaves it where it is.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { railPlacement } from "../src/agent-session/acpmux/threadMinimap/model";
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
let stack = 120;
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

/// The rail's box, from its inline style.
const railBox = () => {
  const rail = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
  return { left: rail.style.left, top: rail.style.top, height: rail.style.height };
};
/// The bottom stack changed size: every observer hears it, as the browser's would.
const stackResized = (height: number) =>
  act(async () => {
    stack = height;
    for (const { callback, self } of observers) callback([], self);
  });

test("a composer that grows over the view, or a tray that opens in the stack, leaves the rail's box as it was", async () => {
  stack = 120;
  const root = createRoot(document.getElementById("root")!);
  const dock = document.getElementById("dock")!;
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(40), new Set())}
        sessionId="rail-box"
        dock={dock}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  try {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    expect(scroller.style.getPropertyValue("--acpmux-dock-space")).toBe("120px");
    const rest = railBox();
    expect(Number.parseFloat(rest.height)).toBeGreaterThan(0);
    // Three more composer lines, then a background-task bar on top of them.
    await stackResized(188);
    expect(scroller.style.getPropertyValue("--acpmux-dock-space")).toBe("188px");
    expect(railBox()).toEqual(rest);
    await stackResized(236);
    expect(railBox()).toEqual(rest);
    // Back to rest: still the same box.
    await stackResized(120);
    expect(railBox()).toEqual(rest);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the rail's inset is the same at every pane width that leaves its gutter room (the sidebar toggle)", () => {
  const insets = [920, 1000, 1040, 1200, 1600, 2400].map((width) => railPlacement(width).left);
  expect(new Set(insets)).toEqual(new Set([16]));
  // Only a gutter too short for the widest step shrinks it.
  expect(railPlacement(800).left).toBe(8);
  // Session Info pushing the chat's column (a smaller text inset) never moves it: it reads the pane.
  expect(railPlacement(1084, 32).left).toBe(railPlacement(1084).left);
});

test("the transcript's mask leaves the rail's lane in full ink", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  );
  const rule =
    /\.acpmux-scroll:has\(> \.acpmux-minimap\):is\(\[data-fade-top\], \[data-fade-bottom\], \[data-docked\]\) \{([^}]*)\}/.exec(
      css,
    )?.[1];
  expect(rule).toBeDefined();
  // The view's mask, the scrollbar's lane, and the rail's lane: the gutter the rows never reach.
  expect(rule).toContain("var(--acpmux-view-mask)");
  expect(rule).toMatch(
    /mask-size:\s*100% 100%,\s*var\(--acpmux-scrollbar-lane, 16px\) 100%,\s*var\(--cv-inset\) 100%;/,
  );
});
