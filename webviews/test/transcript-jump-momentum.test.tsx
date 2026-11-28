// Jump to latest during a trackpad fling's momentum lands at the latest message and stays there
// (Leo 2026-11-12: "if you already have momentum scrolling up, like it doesn't fully jump to the
// bottom. It, like, just maintains momentum"). WebKit keeps sending the fling's momentum as wheel
// events after the jump writes the offset, and moves the view by each: here a wheel event and the
// offset it moves, a frame apart, decaying, as the fling up the chat goes on through the click.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";
import { JUMP_LATEST } from "../src/agent-session/acpmux/transcriptSelectors";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
/// The page's clock, which only the test moves: a frame is 16 ms on it however long the runner took
/// to draw it, and a wheel event is stamped on it. The momentum hold (momentumHold.ts) and the jump's
/// glide read performance.now: on the runner's own clock a loaded machine spread the fling's frames
/// over more real time than they take, the hold lapsed (MOMENTUM_ARRIVAL_MS, MOMENTUM_MAX_MS) mid-fling
/// and the rest of the momentum moved the view (5014 for 5588 under 16 busy jobs, where no hold at
/// all lands).
let now = 1_000;
const pageClock = performance.now;
performance.now = () => now;
const frames = new Map<number, FrameRequestCallback>();
let lastFrame = 0;
const requestFrame = (callback: FrameRequestCallback) => {
  frames.set(++lastFrame, callback);
  return lastFrame;
};
const cancelFrame = (handle: number) => void frames.delete(handle);
dom.window.requestAnimationFrame = requestFrame;
dom.window.cancelAnimationFrame = cancelFrame;
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
  requestAnimationFrame: requestFrame,
  cancelAnimationFrame: cancelFrame,
  IS_REACT_ACT_ENVIRONMENT: true,
};
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

afterAll(async () => {
  performance.now = pageClock;
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
// 24 turns: a cold open lays a chat this long out whole on its first frame (VirtualTranscript.tsx
// `coldOpenRoughAbove`; a longer one opens its history at rough heights, laid out whole a frame later).
// Each reply-only turn draws its Worked for line (turns.ts `holdsHeader`, #51896), so 30 turns crossed that
// line, and these tests read the chat's end and place the reader on its first frame.
const turns = Array.from({ length: 24 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();
/// One display frame: the page's clock moves on 16 ms and the callbacks asked for before it run
/// (those they ask for run in the next one, as a browser's do).
const nextFrame = async () => {
  now += 16;
  const due = [...frames.values()];
  frames.clear();
  for (const callback of due) callback(now);
};

/// One frame of a trackpad scroll: the wheel event over a row, then the browser's own move of the
/// offset by its delta and the scroll event it fires.
const wheelFrame = async (scroller: HTMLElement, deltaY: number) => {
  await act(async () => {
    const over = scroller.querySelector(".acpmux-row") ?? scroller;
    const event = new dom.window.WheelEvent("wheel", { deltaY, bubbles: true, cancelable: false });
    // The platform stamps the wheel with its own time: a frame apart, on the page's clock.
    Object.defineProperty(event, "timeStamp", { value: now });
    over.dispatchEvent(event);
    scroller.scrollTop += deltaY;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await nextFrame();
  });
};

/// A fling up: 30 frames of momentum decaying from 60 px a frame.
const fling = Array.from({ length: 30 }, (_, frame) => -Math.max(1, Math.round(60 * 0.9 ** frame)));

for (const motion of ["off", "on"] as const) {
  test(`Jump to latest mid-fling (motion ${motion}) ends the momentum at the latest message, still following`, async () => {
    if (motion === "off") dom.window.document.documentElement.dataset.agentMotion = "off";
    else delete dom.window.document.documentElement.dataset.agentMotion;
    const root = createRoot(dom.window.document.getElementById("root")!);
    const rows = turnView(turns, new Set());
    const following: boolean[] = [];
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={rows}
            jumpButton
            onToggleActivity={() => {}}
            expanded={new Set()}
            onFollowingChange={(next) => following.push(next)}
          />,
        ),
      );
      const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const latest = scrollerEnd(scroller);
      expect(scroller.scrollTop).toBe(latest);
      const button = () => dom.window.document.querySelector<HTMLButtonElement>(JUMP_LATEST)!;

      // The reader flings up the chat; a few frames in, they press Jump to latest.
      for (const delta of fling.slice(0, 8)) await wheelFrame(scroller, delta);
      expect(scroller.scrollTop).toBeLessThan(latest - VIEWPORT / 2);
      expect(following.at(-1)).toBe(false);
      await act(async () => button().click());
      // The rest of the fling's momentum keeps arriving.
      for (const delta of fling.slice(8)) await wheelFrame(scroller, delta);
      // The jump's own glide (motion on) runs out; nothing more arrives.
      for (let frame = 0; frame < 60; frame += 1) await act(nextFrame);

      expect(scroller.scrollTop).toBe(latest);
      expect(following.at(-1)).toBe(true);
      expect(button().dataset.shown).toBeUndefined();

      // The reader's next gesture, after a pause, is theirs: it scrolls up and lets go of the latest row.
      // The pause is on the page's clock: 150 ms with no event, past MOMENTUM_GAP_MS.
      now += 150;
      for (const delta of [-4, -12, -30]) await wheelFrame(scroller, delta);
      expect(scroller.scrollTop).toBe(latest - 46);
      expect(following.at(-1)).toBe(false);
    } finally {
      await act(async () => root.unmount());
    }
    // A loaded runner takes longer over the same frames; what lands is the page clock's, not its time.
  }, 30_000);
}
