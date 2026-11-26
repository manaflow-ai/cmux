// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// A chat's attach (its first followed frame, `deferHistory` in VirtualTranscript.tsx) reads no row's
// layout in its commit: its rows are measured as a fling's are (`flingMount`), by their observer in the
// browser's own layout pass, which places them before the frame paints. Read in the commit
// (`queueDrawn`'s measure, drawnHeightOf: getBoundingClientRect), each attach laid the page out inside
// React's work (row.measure, about 22 ms of a chat-open attach; goal chat-attach-p95).
// The real VirtualTranscript under jsdom's scroller model (a 600 px view over 60 rows), with the rows'
// ResizeObserver kept so the test reports their first size as the browser would.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const observers = new Set<{
  targets: Set<Element>;
  notify: (entries: { target: Element }[]) => void;
}>();
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
  // Kept, so the test can deliver a row's first size as the browser's layout pass would.
  ResizeObserver: class {
    targets = new Set<Element>();
    constructor(readonly notify: (entries: { target: Element }[]) => void) {
      observers.add(this);
    }
    observe(target: Element) {
      this.targets.add(target);
    }
    unobserve(target: Element) {
      this.targets.delete(target);
    }
    disconnect() {
      observers.delete(this);
    }
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => 600);

// jsdom lays nothing out: a row draws ROW_PX high, and every read of a row's box is counted.
const ROW_PX = 137;
/// The layout's gap between these rows (a prompt and its reply, a reply and the next prompt).
const GAP_PX = 32;
let rowReads = 0;
const box = (height: number) =>
  ({ x: 0, y: 0, top: 0, left: 0, right: 760, bottom: height, width: 760, height, toJSON() {} }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  if (this.classList.contains("acpmux-row")) {
    rowReads += 1;
    return box(ROW_PX);
  }
  return box(0);
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 }) as AcpmuxRow;
const history = () =>
  Array.from({ length: 60 }, (_, index) =>
    index % 2
      ? row(`reply-${index}`, "assistant", `Reply ${index}\n\nwith a second paragraph`)
      : row(`prompt-${index}`, "user", `Prompt ${index}`),
  );
const Row = ({ row: item }: { row: AcpmuxRow }) => <div>{item.text}</div>;
const registry = { user: Row, assistant: Row } as never;

test("a chat's attach reads no row layout in its commit, and its rows' observer places them at the end", async () => {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const scroller = () => host.querySelector<HTMLElement>(".acpmux-scroll")!;
  const mountedRows = () => [...host.querySelectorAll<HTMLElement>(".acpmux-row")];
  try {
    rowReads = 0;
    // The attach's commit alone (a synchronous act: its layout effects, no frame or timer after it).
    act(() =>
      root.render(
        <VirtualTranscript
          rows={history()}
          registry={registry}
          sessionId="chat-attach-no-row-reads"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const shown = mountedRows();
    expect(shown.length).toBeGreaterThan(0);
    // The latest row is drawn, the history above it deferred (`deferHistory`).
    expect(host.querySelector('[data-row-id="reply-59"]')).not.toBeNull();
    expect(host.querySelector('[data-row-id="prompt-0"]')).toBeNull();
    expect(rowReads).toBe(0);

    // The browser lays the new rows out and delivers their first sizes before the frame paints.
    act(() => {
      for (const observer of [...observers]) {
        const targets = [...observer.targets].filter((target) => target.classList.contains("acpmux-row"));
        if (targets.length) observer.notify(targets.map((target) => ({ target })));
      }
    });
    expect(rowReads).toBeGreaterThan(0);
    // Placed at their drawn heights: each mounted row starts its gap below where the one before it
    // ends, where the commit's own read placed them before (5676px, 5845px, ... 6859px on base).
    const placed = mountedRows()
      .map((node) => ({ index: Number(node.getAttribute("aria-posinset")), top: parseFloat(node.style.top) }))
      .sort((a, b) => a.index - b.index);
    expect(placed.at(-1)!.index).toBe(60);
    for (let at = 1; at < placed.length; at += 1)
      if (placed[at]!.index === placed[at - 1]!.index + 1)
        expect(placed[at]!.top - placed[at - 1]!.top).toBe(ROW_PX + GAP_PX);
    // Still at the chat's end: the follow anchoring took the rows' drawn heights.
    expect(scroller().scrollTop).toBe(scrollerEnd(scroller()));
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});
