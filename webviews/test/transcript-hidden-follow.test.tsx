// cx-t0zqt: a chat at the latest message keeps following it across a stretch hidden (Home shown in
// its place). The hidden scroller has no height; a scroll there must not read as "scrolled up", or
// the chat stops following and reopens on an old turn.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
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
// 0 while the pane is hidden, and a scroll offset the test moves as the browser would.
const VIEWPORT = 600;
let viewport = VIEWPORT;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => viewport);

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

test("a chat at the latest message still follows it after a stretch hidden", async () => {
  const rows = turnView(turns, new Set());
  const anchors: Anchor[] = [];
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const latest = () => scrollerEnd(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!);
  const render = (shown: AcpmuxRow[]) =>
    root.render(
      <VirtualTranscript
        rows={shown}
        onAnchor={(a) => anchors.push(a)}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    );
  try {
    await act(async () => render(rows));
    expect(scroller().scrollTop).toBe(latest());

    // Home is shown: the pane is hidden and its scroller reports a scroll with no height.
    viewport = 0;
    // The scroll's anchor reports once the scroll has rested; the test moves the clock past that.
    jest.useFakeTimers();
    try {
      await act(async () => void scroller().dispatchEvent(new dom.window.Event("scroll")));
      await act(async () => void jest.advanceTimersByTime(SCROLL_ANCHOR_SETTLE_MS + 50));
    } finally {
      jest.useRealTimers();
    }
    expect(anchors.filter((a) => a !== null)).toEqual([]);

    // Back in the chat, a new turn arrives: the view follows it to the latest message.
    viewport = VIEWPORT;
    const more = turnView(
      [
        ...turns,
        row("t30-user", "user", "Question 30"),
        row("t30-answer", "assistant", "Answer 30.\n\nWith a second paragraph so the turn has height."),
      ],
      new Set(),
    );
    await act(async () => render(more));
    expect(scroller().scrollTop).toBe(latest());
  } finally {
    viewport = VIEWPORT;
    await act(async () => root.unmount());
  }
});
