// Leo, 2026-11-11 (ask-9d22a47adb): "then there's the thinking, or maybe there's a tooltip, and I
// scroll down to the bottom. I have to, like, scroll down again because it didn't realize". A reader
// whose view sits at the scroller's end without following (a row landed as they got there, so the
// scroll event that brought them read short of the layout's end) wheels down: the browser scrolls
// nothing and sends no scroll event, and that wheel alone follows the latest row again.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
dom.window.document.documentElement.dataset.agentMotion = "off";
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
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

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
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

test("a wheel down at the scroller's end follows the latest row again, with no scroll event", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView(turns, new Set());
  const changes: boolean[] = [];
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          onToggleActivity={() => {}}
          expanded={new Set()}
          onFollowingChange={(following) => changes.push(following)}
        />,
      ),
    );
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const latest = scrollerEnd(scroller);
    // The reader scrolls up: following ends.
    await act(async () => {
      scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -120, bubbles: true }));
      scroller.scrollTop = latest - 300;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(changes.at(-1)).toBe(false);
    // The view comes to the scroller's end by a move that reads as no downward input of the reader's.
    await act(async () => {
      scroller.scrollTop = latest;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(changes.at(-1)).toBe(false);
    // A wheel down there scrolls nothing: it alone follows again.
    await act(async () => {
      scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 40, bubbles: true }));
      await nextFrame();
    });
    expect(changes.at(-1)).toBe(true);
    expect(scroller.scrollTop).toBe(latest);
  } finally {
    await act(async () => root.unmount());
  }
});
