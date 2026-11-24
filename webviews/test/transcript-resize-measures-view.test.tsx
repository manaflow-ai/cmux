// A pane resized beside a long chat (a divider or window edge dragged, the sidebar or a split opening) measures
// the rows around the view at the new width, not every row the chat holds: the cost of a width step and of the
// settle after a drag must not grow with the chat (Leo, 2026-10-27: "the resized chromium pane still lagging ...
// when recalculating size/layout"). Counts the transcript's row measurements (a registry renderer's `measure`,
// which the layout calls for each row it measures) at two chat lengths.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { installJsdomScroller } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const observers: { callback: () => void; targets: Element[] }[] = [];
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
  // Each observer keeps its callback and targets, so the test reports a resize as the browser does.
  ResizeObserver: class {
    targets: Element[] = [];
    constructor(readonly callback: () => void) {
      observers.push(this);
    }
    observe(target: Element) {
      this.targets.push(target);
    }
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

// jsdom has no layout: the box's width is the one the test gives it, its height a fixed view.
let boxWidth = 760;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => boxWidth,
});
// The scroller is a laid-out box: the transcript ignores a resize of a box with no client rects (a hidden
// view), and jsdom gives every element none.
const layoutBox = () => ({ x: 0, y: 0, top: 0, left: 0, right: boxWidth, bottom: 600, width: boxWidth, height: 600 });
const noRects = dom.window.HTMLElement.prototype.getClientRects;
dom.window.HTMLElement.prototype.getClientRects = function (this: HTMLElement) {
  if (!this.classList.contains("acpmux-scroll")) return noRects.call(this);
  return Object.assign([layoutBox()], { item: () => layoutBox() }) as unknown as DOMRectList;
};
installJsdomScroller(dom.window as never, () => 600);
dom.window.HTMLElement.prototype.animate = function () {
  return { cancel() {}, finish() {} } as unknown as Animation;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

/// Rows measured since the last reset: the registry's `measure` runs once per row the layout measures.
let measured = 0;
function SizedRow({ row }: { row: AcpmuxRow }) {
  return <div>{row.text}</div>;
}
const registry = {
  sized: Object.assign(SizedRow, {
    measure: (row: AcpmuxRow, width: number) => {
      measured += 1;
      return 20 * Math.max(1, Math.ceil(((row.text?.length ?? 0) * 7) / Math.max(1, width)));
    },
  }),
};
const chat = (count: number): AcpmuxRow[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `row-${index}`,
    kind: "sized",
    text: `Row ${index}: ${"a line of text that wraps at narrower widths ".repeat(1 + (index % 4))}`,
    version: 1,
    at: index,
  }));

/// Real time passing: a drag's width steps come a frame apart, and the transcript settles 120 ms after the width holds.
function elapse(ms: number) {
  // A late wake only spreads the drag's steps apart (each then settles alone): more rows measured, never fewer.
  // fixed-wait: the drag's frames and the settle run on real timers, so a slow runner cannot hide a whole-chat layout.
  return new Promise((resolve) => setTimeout(resolve, ms));
}
const settle = () => elapse(200);

/// Rows measured by one width step, and by a drag (steps a frame apart) with its settle once the width held.
async function resizeCost(count: number): Promise<{ step: number; drag: number }> {
  boxWidth = 760;
  observers.length = 0;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const rows = chat(count);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId={`chat-${count}`}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
    const resize = observers.find((observer) => observer.targets.includes(scroller))!;
    expect(resize).toBeDefined();
    await act(settle);
    // One width step: the sidebar or a split opening.
    measured = 0;
    boxWidth = 640;
    await act(async () => resize.callback());
    await act(settle);
    const step = measured;
    // A drag: a width step a frame, then the width holds and the rows are placed at it.
    measured = 0;
    for (const width of [630, 610, 590, 570, 550, 530, 520]) {
      boxWidth = width;
      await act(async () => {
        resize.callback();
        await elapse(16);
      });
    }
    await act(settle);
    return { step, drag: measured };
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
}

test("a width change measures the rows around the view, at any chat length", async () => {
  const short = await resizeCost(2_000);
  const long = await resizeCost(20_000);
  // Measured whole, a step costs every row the chat holds (2,000 and 20,000).
  expect(long.step).toBeGreaterThan(0);
  expect(long.step).toBeLessThan(400);
  expect(long.drag).toBeLessThan(1_200);
  // Flat in the chat's length: ten times the rows, about the same measurements.
  expect(long.step).toBeLessThanOrEqual(short.step * 1.2 + 10);
  expect(long.drag).toBeLessThanOrEqual(short.drag * 1.2 + 10);
});
