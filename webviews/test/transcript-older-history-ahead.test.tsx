// A reader scrolling up fast asks for the older page as far ahead as their speed covers in a page's
// read, not only within the fixed six viewports: a flick reached the loaded rows' top while the page
// was still out and stopped there with nothing above (Leo 2026-11-12: "I'm just getting some blanks
// in between loads as I scroll up. Like, it just doesn't catch up to my speed of scrolling").
import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Each element's ResizeObserver callback, which the test fires as a redrawn row would.
const observers = new Map<Element, (entries: { target: Element }[]) => void>();
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
    constructor(private readonly callback: (entries: { target: Element }[]) => void) {}
    observe(target: Element) {
      observers.set(target, this.callback);
    }
    unobserve(target: Element) {
      observers.delete(target);
    }
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

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
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
// jsdom has no layout: each row draws at a height of its own, which a redraw can change.
const drawnHeights = new Map<string, number>();
const drawnHeight = (id: string) => drawnHeights.get(id) ?? 40 + (id.length % 7) * 9;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? drawnHeight(this.dataset.rowId) : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const turn = (index: number) => [
  row(`t${index}-user`, "user", { text: `Question ${index}` }),
  row(`t${index}-answer`, "assistant", { text: `Answer ${index}.` }),
  row(`t${index}-end`, "turnSummary", { status: "completed", durationMs: 1_000 }),
];

/// One display frame at 60 Hz (ms).
const FRAME_MS = 1000 / 60;

async function scrollUp(step: number) {
  const history = Array.from({ length: 120 }, (_, index) => turn(index + 1000)).flat();
  const root = createRoot(dom.window.document.getElementById("root")!);
  // Where the view was, among the rows, each time it asked.
  const askedAt: number[] = [];
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const onLoadOlder = () => {
    askedAt.push(scroller().scrollTop);
    return new Promise<void>(() => {});
  };
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(history, new Set(), { working: false, now: at })}
        onToggleActivity={() => {}}
        expanded={new Set()}
        canLoadOlder
        onLoadOlder={onLoadOlder}
        sessionId={`s-speed-${step}`}
      />,
    ),
  );
  // The reader's scroll: the offset moves up by `step`, then one scroll event, a display frame apart.
  // The frame is on the test's clock, not the host's: the transcript reads the reader's speed (px/ms)
  // from `performance.now()`, and on a busy runner jsdom's frames came a millisecond or two apart, so
  // 40 px a frame read as a flick and asked far above six viewports (base red, cmux run 43607255887).
  let clock = performance.now();
  const now = spyOn(performance, "now").mockImplementation(() => clock);
  const scrollBy = async (delta: number) =>
    act(async () => {
      clock += FRAME_MS;
      scroller().scrollTop = Math.max(0, scroller().scrollTop + delta);
      scroller().dispatchEvent(new dom.window.Event("scroll"));
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    });
  const trace: string[] = [];
  try {
    const start = scroller().scrollTop;
    trace.push(`start ${start} asked ${askedAt.length}`);
    // The tail opened far below the fixed reach, so nothing was asked for yet.
    expect(start).toBeGreaterThan(VIEWPORT * 20);
    expect(askedAt).toEqual([]);
    for (let frame = 0; frame < 400 && scroller().scrollTop > VIEWPORT * 7; frame += 1) {
      await scrollBy(-step);
      if (trace.length < 60) trace.push(`${Math.round(scroller().scrollTop)}:${askedAt.length}`);
    }
    return askedAt;
  } finally {
    console.log(`step ${step}: ${trace.join(" ")} asked at ${askedAt.map(Math.round).join(",")}`);
    now.mockRestore();
    await act(async () => root.unmount());
  }
}

test("a fast scroll up asks for the older page before the fixed six viewports", async () => {
  // Hundreds of px a frame: a flick.
  const askedAt = await scrollUp(500);
  expect(askedAt.length).toBeGreaterThan(0);
  expect(askedAt[0]!).toBeGreaterThan(VIEWPORT * 7);
});

test("a reading scroll asks no earlier than before", async () => {
  // Tens of px a frame: its reach over a page's read is under the fixed six viewports.
  const askedAt = await scrollUp(40);
  expect(askedAt.filter((top) => top > VIEWPORT * 6)).toEqual([]);
}, 60_000);
