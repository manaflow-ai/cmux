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
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a viewport the test resizes (the pane's tab strip showing or hiding) over a
// long conversation, and a scroll offset kept as the browser keeps it.
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => viewport);

// The glides the transcript starts (content that grew at the latest row slides in).
const glides: unknown[] = [];
dom.window.HTMLElement.prototype.animate = function (keyframes: unknown) {
  glides.push(keyframes);
  return { cancel() {}, finish() {} } as unknown as Animation;
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

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 30 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

// cx-f6i7: a chat shown again after the tab over it closed (its strip hides, the pane grows) drew
// its transcript at the old offset and then caught up over the next frames. A resize at the latest
// message lands at the new latest offset before the frame paints, and does not glide: only content
// that grew glides in.
test("a resized chat at its latest message stays there in the same frame, without a glide", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const latest = () => scrollerEnd(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    expect(scroller().scrollTop).toBe(latest());
    const resize = observers.find((observer) => observer.targets.includes(scroller()))!;
    for (const height of [540, 600, 640]) {
      glides.length = 0;
      viewport = height;
      // Read inside the observer's turn: what the browser paints right after it.
      let painted = -1;
      await act(async () => {
        resize.callback();
        painted = scroller().scrollTop;
      });
      expect(painted).toBe(latest());
      expect(glides).toEqual([]);
    }
  } finally {
    await act(async () => root.unmount());
  }
});
