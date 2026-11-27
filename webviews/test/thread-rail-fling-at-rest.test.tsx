// The prompt rail while the chat flings (Leo: "how about speeding up the scrolling up of chats?" / "as
// in i scroll up and it loads the stuff"). A CPU profile of one fling up a 100k-row chat
// (bench/transcript-scroll-up.bench.ts) spent 95 s of 222 s in the rail's list placement: every fling
// frame moves the band, and the effect that keeps the band in the rail's view wrote the list's
// `scrollTop` there, the frame's first forced layout after the transcript mounted its new rows, so it
// paid their style and layout inside the effect. While the chat flings the list now holds still and is
// placed once at rest, where it would have been.
//
// jsdom has no layout, so this counts the writes to the list's offset across a fling's frames: each one
// is a forced layout in a browser.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";
import { railFrame } from "./support/railFrame";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };
// The whole transcript renders once per frame; jsdom is slow at it.
setDefaultTimeout(60_000);

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

// The clock the rail reads a fling's speed from: a 60 Hz frame per frame the test runs, however long
// jsdom takes to render it.
const realNow = performance.now.bind(performance);
let clock = realNow();
performance.now = () => clock;
const FRAME_MS = 16;

// jsdom has no layout: a 600 px viewport over a long conversation, and scroll offsets the test moves.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
const offsets = new WeakMap<object, number>();
/// Each write to the rail list's offset (a forced layout in a browser), and who waits for the next.
let listWrites = 0;
let nextListWrite: (() => void) | undefined;
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: HTMLElement, value: number) {
    offsets.set(this, value);
    if (!this.classList.contains("acpmux-minimap__list")) return;
    listWrites += 1;
    nextListWrite?.();
    nextListWrite = undefined;
  },
});

const { act } = await import("react");
// A fling's frame: the trackpad's momentum wheel event, then the scroll it made; the minimap places its
// band in the frame after the scroll event, as a browser runs it. The wheel carries no delta, so the
// transcript's own wheel handling moves nothing: the test sets the offset the fling reached.
const scrolledFrame = (target: EventTarget) =>
  act(async () => {
    clock += FRAME_MS;
    target.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 0, bubbles: true }));
    target.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(null)));
  });
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  performance.now = realNow;
  await teardownDom(saved, { window: dom.window, scope });
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
/// Far more prompts than the rail has room for, so its list scrolls.
const TURNS = 300;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`user-${index + 1}`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

test("a fling up the chat writes the rail's list offset at most twice, then places it once at rest", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="rail-fling"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    await railFrame();
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const list = () => document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const bottom = scroller.scrollTop;
    // The list opens at its end, with the chat's latest prompts.
    expect(list()).not.toBeNull();
    expect(list().scrollTop).toBeGreaterThan(0);
    const step = Math.ceil(bottom / 20);
    // Hundreds of px a 16 ms frame: a fling (the bench's moves 1,500 to 3,000).
    expect(step).toBeGreaterThan(400);
    const before = listWrites;
    let frames = 0;
    for (let top = bottom - step; top > 0; top -= step) {
      scroller.scrollTop = top;
      await scrolledFrame(scroller);
      frames += 1;
    }
    scroller.scrollTop = 0;
    await scrolledFrame(scroller);
    frames += 1;
    const lit = () =>
      [...list().querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')].map((tick) =>
        Number(tick.dataset.tick),
      );
    // The list wrote its offset only for the fling's first frames (base: once a frame, 20 forced
    // layouts), and is still where those left it: the band's ticks at the top are not in its view yet.
    expect(frames).toBeGreaterThanOrEqual(19);
    expect(listWrites - before).toBeLessThanOrEqual(2);
    expect(list().scrollTop).toBeGreaterThan(0);
    // At rest the list is placed once, where the band at the chat's top puts it: its own top.
    // The rest timer's render runs as the app's does, outside act (whose queue would hold it until the
    // write it waits for): the test waits for that write.
    const atRest = listWrites;
    scope.IS_REACT_ACT_ENVIRONMENT = false;
    try {
      await new Promise<void>((resolve) => {
        nextListWrite = resolve;
      });
    } finally {
      scope.IS_REACT_ACT_ENVIRONMENT = true;
    }
    await act(async () => {});
    expect(listWrites - atRest).toBe(1);
    expect(list().scrollTop).toBe(0);
    expect(lit()).toContain(0);
  } finally {
    await act(async () => root.unmount());
  }
});
