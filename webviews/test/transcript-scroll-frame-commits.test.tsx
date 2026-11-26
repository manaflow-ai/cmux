// Leo, 2026-11-16 (ask-52957039cb): "idk we've measured tons of shit already you guys should all be
// trying to optimize the f*** out of things". His NIGHTLY under load scrolled the agent chat at about
// 4 fps: every scroll frame rendered the whole transcript synchronously (scrollPacer's flushSync),
// even a frame that mounted no other row and moved nothing React draws. A reader's slow scroll in
// the middle of a chat, a pixel a frame, now renders the transcript only when what it draws changes.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";
import { settleReact } from "./support/domTeardown";

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

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { acpmuxPerf } = await import("../src/agent-session/acpmux/perf");

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 60 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

/// Pixel-a-frame steps of a slow read.
const STEPS = 12;

test("a slow scroll mid-chat renders the transcript only when what it draws changes", async () => {
  acpmuxPerf.enable(dom.window.document);
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView(turns, new Set());
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />),
    );
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    // The reader scrolls up into the middle of the chat: following ends, the rows there mount.
    await act(async () => {
      scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -120, bubbles: true }));
      scroller.scrollTop = scrollerEnd(scroller) - 1_500;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
      await nextFrame();
    });
    expect(scroller.querySelectorAll(".acpmux-row").length).toBeGreaterThan(0);
    const step = () =>
      act(async () => {
        scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -1, bubbles: true }));
        scroller.scrollTop -= 1;
        scroller.dispatchEvent(new dom.window.Event("scroll"));
        await nextFrame();
      });
    // The first slow step changes the scroll's lead (from the long move to a pixel): that one draws.
    await step();
    await step();
    acpmuxPerf.resetRenders();
    // Then reads on, a pixel a frame, inside the rows already mounted and far from either end.
    for (let frame = 0; frame < STEPS; frame += 1) await step();
    const renders = acpmuxPerf.renders.get("transcript") ?? 0;
    console.log(`SCROLL-FRAME-COMMITS steps=${STEPS} transcript_renders=${renders}`);
    // A row's edge crossing the view's may fall inside the run (a commit and its deferred render),
    // never a render a frame: the base rendered about three a frame (37 over 12 steps).
    expect(renders).toBeLessThanOrEqual(STEPS / 2);
    // The rows the reader sees are still drawn.
    expect(scroller.querySelectorAll(".acpmux-row").length).toBeGreaterThan(0);
  } finally {
    acpmuxPerf.enabled = false;
    await act(async () => root.unmount());
  }
});
