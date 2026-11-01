// cx-6bgzj: a chat reopens where the reader left it. The transcript reports where it rests once a
// scroll settles (a row and the offset into it, or nothing at the latest message) and opens at such a
// place after a relaunch, a crash or a reload instead of at the latest message.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { layoutScrollTop } from "../src/agent-session/acpmux/conversation/scrollCoordinates";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";

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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript, SCROLL_ANCHOR_SETTLE_MS } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 30 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

type Anchor = { rowId: string; offset: number } | null;
/// A scroll, then the pause after it on a fake clock: one report once the scroll has rested
/// SCROLL_ANCHOR_SETTLE_MS, and none a moment before.
async function scrollAndRest(scroller: HTMLElement, top: number, anchors: Anchor[]) {
  jest.useFakeTimers();
  try {
    const reported = anchors.length;
    // A reader scroll starts with input: a layout-driven scroll alone must not resume follow.
    await act(
      async () =>
        void scroller.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", {
            key: top < scroller.scrollTop ? "PageUp" : "End",
            bubbles: true,
          }),
        ),
    );
    scroller.scrollTop = top;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    await act(async () => void jest.advanceTimersByTime(SCROLL_ANCHOR_SETTLE_MS - 1));
    expect(anchors.length).toBe(reported);
    await act(async () => void jest.advanceTimersByTime(1));
    expect(anchors.length).toBe(reported + 1);
  } finally {
    jest.useRealTimers();
  }
}

test("a scrolled-up chat reports where it rests and reopens there, not at the latest message", async () => {
  const rows = turnView(turns, new Set());
  const anchors: Anchor[] = [];
  let root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          onAnchor={(a) => anchors.push(a)}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const latest = scrollerEnd(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!);
    expect(scroller().scrollTop).toBe(latest);

    // The reader scrolls up and stops: one report, a row and how far into it.
    const resting = Math.round(latest / 3);
    await scrollAndRest(scroller(), resting, anchors);
    const logicalResting = layoutScrollTop(scroller());
    const anchor = anchors.at(-1);
    expect(anchor).toBeTruthy();
    expect(rows.some((row) => row.id === anchor!.rowId)).toBe(true);
    expect(anchor!.offset).toBeGreaterThanOrEqual(0);

    // A relaunch preserves the logical row position. The browser can round the physical
    // offset differently; the retained CSS origin must keep the same painted coordinate.
    await act(async () => root.unmount());
    root = createRoot(dom.window.document.getElementById("root")!);
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          openAt={anchor!}
          onAnchor={(a) => anchors.push(a)}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    expect(layoutScrollTop(scroller())).toBe(logicalResting);
    expect(Math.abs(scroller().scrollTop - logicalResting)).toBeLessThanOrEqual(1);
    // The DOM correction, not just the coordinate bookkeeping, must preserve the rendered place.
    const cssOrigin = Number.parseFloat(scroller().style.getPropertyValue("--acpmux-scroll-origin")) || 0;
    expect(scroller().scrollTop - cssOrigin).toBe(logicalResting);

    // Back at the latest message: the place is forgotten, so the next open follows the reply.
    await scrollAndRest(scroller(), latest, anchors);
    expect(anchors.at(-1)).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a place whose row is gone opens at the latest message", async () => {
  const rows = turnView(turns, new Set());
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          openAt={{ rowId: "no-such-row", offset: 12 }}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const latest = scrollerEnd(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!);
    expect(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop).toBe(latest);
  } finally {
    await act(async () => root.unmount());
  }
});

test("switching chats opens the new chat at latest instead of the old chat's scroll offset", async () => {
  const rowsA = turnView(turns, new Set());
  const rowsB = turnView(
    turns.map((one) => ({ ...one, id: `session-b-${one.id}` })),
    new Set(),
  );
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={rowsA} sessionId="session-a" onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const resting = Math.round(scroller().scrollTop / 3);
    scroller().scrollTop = resting;
    await act(async () => void scroller().dispatchEvent(new dom.window.Event("scroll")));
    expect(scroller().scrollTop).toBe(resting);

    await act(async () =>
      root.render(
        <VirtualTranscript rows={rowsB} sessionId="session-b" onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const latest = scrollerEnd(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!);
    expect(scroller().scrollTop).toBe(latest);
  } finally {
    await act(async () => root.unmount());
  }
});
