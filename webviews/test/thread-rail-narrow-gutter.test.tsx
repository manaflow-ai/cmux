// The prompt rail in a narrow pane's gutter (Leo, 2026-11-01: "also when things shrink it should be
// able to be more easily hoverable it's just kinda flickering in and out of being accessible at smaller
// viewpoints even though it certainly has enough space just shrink its padding more it can even have a
// dedicated space for more"). The default `tight` gutter (gutter.experiment.ts) shrinks the rail's
// inset and hit width before anything hides, so the resting rail fits the page edge every transcript
// keeps and stays drawn and hoverable at every width.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Reduce Motion is on unless a test turns it off: the occluded rail's leave grace is skipped under it.
let reduceMotion = true;
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
  // Reduce Motion: scrolls land at once, so a test reads where they land.
  matchMedia: (query: string) => ({ matches: reduceMotion && query.includes("reduce"), media: query }),
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

// jsdom has no layout: a 600 px viewport, a pane `paneWidth` wide, and a scroll offset.
const VIEWPORT = 600;
let paneWidth = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => paneWidth });
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
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
// acpmux's bookmarks for the chat, answering at once (thread-bookmarks.test.tsx covers its replies).
const acpmuxMarks = new Set<number>();
setBookmarkTransport({
  get: async (sessionId) => ({ sessionId, bookmarks: [...acpmuxMarks] }),
  set: async (sessionId, seq, bookmarked) => {
    if (bookmarked) acpmuxMarks.add(seq);
    else acpmuxMarks.delete(seq);
    return { sessionId, bookmarks: [...acpmuxMarks] };
  },
});

afterAll(() => {
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});
afterEach(() => {
  paneWidth = 1040;
  reduceMotion = true;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    // Prompt rows are `user-<seq>`, the seq acpmux logs them at (a bookmark names it).
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

async function mount(prompts: number) {
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(prompts), new Set())}
        sessionId="rail-narrow"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const scrolled = () => act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
  await act(async () => {
    scroller.scrollTop = 0;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
  });
  return { root, scroller, scrolled, unmount: () => act(async () => root.unmount()) };
}

const ticks = () => [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")];
const tick = (index: number) => ticks()[index]!;
/// A tick's drawn length in px, from its bar's scale of the 26 px box.
const length = (index: number) =>
  26 *
  Number(
    /scaleX\(([\d.]+)\)/.exec(tick(index).querySelector<HTMLElement>(".acpmux-minimap__bar")!.style.transform)?.[1],
  );
const pointer = (type: string, target: Element, init: Record<string, unknown> = {}) =>
  act(async () => {
    const Event = (dom.window as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? dom.window.MouseEvent;
    target.dispatchEvent(new Event(type, { bubbles: true, cancelable: true, button: 0, ...init }));
  });
const enter = (index: number) => pointer("pointerover", tick(index), { relatedTarget: document.body });
const leave = (index: number) => pointer("pointerout", tick(index), { relatedTarget: document.body });

/// The rail's box, from its inline style.
const railBox = () => {
  const rail = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail");
  if (!rail) return undefined;
  return { left: Number.parseFloat(rail.style.left), width: Number.parseFloat(rail.style.width), rail };
};

const { railPlacement } = await import("../src/agent-session/acpmux/threadMinimap/model");
const { transcriptColumn } = await import("../src/agent-session/acpmux/model");
const { gridLength } = await import("../src/agent-session/acpmux/transcriptGrid");
/// The column's minimum edge: the grid's 16 that conversation.css `--cv-edge` and model.ts
/// `transcriptColumn` both read (leo-workspace design/grid.md 5.5 Columns: "the minimum edge is 16
/// (today's 18 moves to it)", #27580).
const MIN_EDGE = gridLength("icon-box");
const TIGHT = { min: 4, max: 16, compact: 12, narrowest: 12 };

test("the tight gutter fits the resting rail beside the text at every pane width", () => {
  for (let width = 120; width <= 2400; width += 20) {
    const inset = transcriptColumn(width).inset;
    const placement = railPlacement(width, inset, TIGHT);
    expect({ width, overlaps: placement.overlapsText }).toEqual({ width, overlaps: false });
    expect(placement.left + placement.width).toBeLessThanOrEqual(inset);
  }
});

test("its padding shrinks first, then its hit width, as the pane narrows", () => {
  const at = (width: number) => railPlacement(width, transcriptColumn(width).inset, TIGHT);
  expect(at(1040)).toMatchObject({ left: 16, width: 36 });
  expect(at(800)).toMatchObject({ left: 4, width: 36 });
  expect(at(760)).toMatchObject({ left: 4, width: 16 });
  // At its minimum edge the rail's hit width is what the edge leaves after its 4 inset (12 on the grid).
  expect(at(320)).toMatchObject({ left: 4, width: MIN_EDGE - 4 });
});

for (const width of [320, 520, 760, 800])
  test(`a ${width} px pane draws the rail at rest and it stays hoverable, with the full wave over the text`, async () => {
    paneWidth = width;
    const view = await mount(12);
    try {
      const box = railBox()!;
      expect(box.rail.hasAttribute("data-occluded")).toBe(false);
      await enter(5);
      expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(false);
      // Hovered, it is wide enough for the magnified ticks: 26 px, then 20, 14 and 10 px.
      expect(railBox()!.width).toBeGreaterThanOrEqual(30);
      expect(ticks().map((_, index) => Math.round(length(index)))).toEqual([6, 6, 10, 14, 20, 26, 20, 14, 10, 6, 6, 6]);
      await leave(5);
      await pointer("pointerout", railBox()!.rail, { relatedTarget: document.body });
      expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(false);
      expect(railBox()!.width).toBe(box.width);
    } finally {
      await view.unmount();
    }
  });
