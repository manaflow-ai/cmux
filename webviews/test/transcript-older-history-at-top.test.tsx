// A reader who scrolls to the top keeps getting older pages until the first message (perf100
// chat-load). A page that lands moves the view down by its own height to keep the reader's row in
// place; the reader's scroll back to the top could land before that move ever reached the
// transcript's state, so the rendered offset never changed and the transcript never asked for the
// next page: a scroll to the first message stalled at the top after a few pages.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

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

afterAll(() => {
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

test("a reader back at the top after a page lands gets the next page", async () => {
  let history = Array.from({ length: 12 }, (_, index) => turn(index + 100)).flat();
  const root = createRoot(dom.window.document.getElementById("root")!);
  let asked = 0;
  let land: (() => void) | undefined;
  const onLoadOlder = () => {
    asked += 1;
    return new Promise<void>((resolve) => (land = resolve));
  };
  const draw = async (connected = true) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(history, new Set(), { working: false, now: at })}
          onToggleActivity={() => {}}
          expanded={new Set()}
          canLoadOlder
          onLoadOlder={connected ? onLoadOlder : undefined}
          sessionId="s-top"
        />,
      ),
    );
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  // The reader's scroll: the offset moves, then one scroll event, as a frame delivers it.
  const scrollTo = async (top: number) =>
    act(async () => {
      scroller().scrollTop = top;
      scroller().dispatchEvent(new dom.window.Event("scroll"));
      // The virtual range commits on the next display frame, just as a real reader sees it.
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    });
  try {
    await draw();
    await scrollTo(0);
    const first = asked;
    expect(first).toBeGreaterThanOrEqual(1);
    for (let page = 1; page <= 3; page += 1) {
      const anchorId = history[0]!.id;
      const anchor = scroller().querySelector(`[data-row-id="${anchorId}"]`);
      expect(anchor).not.toBeNull();
      // A page of older turns lands above the first row, far taller than two viewports: the view
      // moves down to keep the reader's row, and the reader scrolls straight back to the top.
      history = [...Array.from({ length: 30 }, (_, index) => turn(100 - page * 30 + index)).flat(), ...history];
      land?.();
      await draw();
      expect(scroller().scrollTop).toBeGreaterThan(VIEWPORT * 2);
      // Correcting scrollTop after reconciliation is too late: the same visible row must keep
      // its DOM node, including any open details and local state, through the prepend itself.
      expect(scroller().querySelector(`[data-row-id="${anchorId}"]`)).toBe(anchor);
      await scrollTo(0);
      expect(asked).toBe(first + page);
    }
    // Disconnect while the last page is pending. Its settlement must not re-arm a stale 500 ms
    // retry; reconnecting starts exactly one fresh request on this same mounted transcript.
    const beforeDisconnect = asked;
    await draw(false);
    land?.();
    await act(async () => Promise.resolve());
    await draw(true);
    expect(asked).toBe(beforeDisconnect + 1);
    // fixed-wait: allow the stale retry window to elapse before checking it did not re-arm.
    await new Promise((resolve) => setTimeout(resolve, 550));
    expect(asked).toBe(beforeDisconnect + 1);
  } finally {
    await act(async () => root.unmount());
  }
});
