// The hat's leaving copy folds ONE time (subagents/trayMotionModel.ts `startOnFirstFrames`).
//
// The copy's fold starts on the frames the page paints: after a late frame early in the fold, its
// clock is held near what the page last painted, so the frame after a stall is not most of the way
// down. That hold must never move the clock BACK. Two WebKit runs of composer-hat-leave-fold showed
// it doing that (jobs 130354389043 and 130376583220, 2026-11-11): the copy was 95% folded (105.5 px
// of 132, 75 ms into the 180 ms settle), one frame came 60 ms late, and the next frame drew the hat
// at 118.9 px again, the height of the fold's first frame. The person saw the hat nearly gone, back,
// and gone again.
//
// This drives the model alone, with the page's frames and the copy's animation clock in the test's
// hands: each frame is given its time, and the copy's clock is read after each frame's callbacks, which
// is the value that frame paints.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=host></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const GHOST = "acpmux-running-tray--ghost";
/// The house settle, as the stylesheet resolves it on the copy (subagents.css `--acpmux-tray-leave`).
const LEAVE_MS = 180;
const FRAME_MS = 1000 / 60;

const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
const host = dom.window.document.getElementById("host")!;
Object.defineProperty(proto, "offsetParent", { configurable: true, get: () => host });
Object.defineProperty(proto, "offsetHeight", { configurable: true, get: () => 28 });
proto.getBoundingClientRect = function (this: HTMLElement) {
  return this === host ? { top: 0, left: 0, width: 400, height: 300 } : { top: 200, left: 0, width: 400, height: 28 };
};
// Web Animations exist (the model checks `animate` before it moves anything).
proto.animate = () => ({ cancel() {} });
const computed = dom.window.getComputedStyle.bind(dom.window);
dom.window.getComputedStyle = ((node: Element) =>
  node.classList.contains(GHOST)
    ? ({ animationName: "acpmux-tray-leave", animationDuration: "0.18s" } as CSSStyleDeclaration)
    : computed(node)) as typeof dom.window.getComputedStyle;

/// The page's clock and its frame callbacks, both driven by `paint`.
let now = 0;
let queued: ((at: number) => void)[] = [];
(dom.window as unknown as { requestAnimationFrame: unknown }).requestAnimationFrame = (run: (at: number) => void) => {
  queued.push(run);
  return queued.length;
};

/// The copy's one CSS animation. Its clock starts on the first frame after the copy is made, as a
/// CSS animation's does, then follows the page's clock unless the model writes it.
const clock = { started: undefined as number | undefined, offset: 0 };
const leave = {
  get currentTime(): number {
    return clock.started === undefined ? 0 : Math.min(LEAVE_MS, now - clock.started + clock.offset);
  },
  set currentTime(value: number) {
    clock.started = now;
    clock.offset = value;
  },
};
proto.getAnimations = function (this: HTMLElement) {
  return this.classList.contains(GHOST) ? [leave] : [];
};

/// Paints one frame at `at` ms: the frame callbacks run, then the copy's clock is what the frame shows.
function paint(at: number): number {
  now = at;
  if (clock.started === undefined) clock.started = at;
  const run = queued;
  queued = [];
  for (const callback of run) callback(at);
  return leave.currentTime;
}

const { playTrayExit, settleTrayExit } = await import("../src/agent-session/acpmux/subagents/trayMotionModel");

/// Starts the copy's fold at time 0 and paints a frame at each of `times`; the clock each frame showed.
function fold(times: readonly number[]): number[] {
  now = 0;
  queued = [];
  clock.started = undefined;
  clock.offset = 0;
  // As React does it: the exit plays while the card is still laid out, then the card goes.
  const card = dom.window.document.createElement("div");
  card.className = "acpmux-running-tray";
  host.append(card);
  playTrayExit(card);
  card.remove();
  expect(host.querySelector(`.${GHOST}`), "the leaving copy is in the stack").not.toBeNull();
  return times.map(paint);
}

afterEach(() => settleTrayExit());

describe("the hat's leaving copy folds one time", () => {
  // The WebKit trace of job 130376583220: frames at +16 and +32, a 65 ms gap, three steady frames, then
  // a 61 ms gap while the fold's clock is at 75 ms of its 180 ms.
  const TRACE = [16, 32, 97, 116, 136, 155, 216, 234, 254];
  // The same, with the second gap one frame sooner.
  const SOONER = [16, 32, 97, 116, 136, 196, 214, 232];

  for (const [name, times] of [
    ["the WebKit trace", TRACE],
    ["a second gap one frame sooner", SOONER],
  ] as const) {
    test(`a late frame in the fold never moves its clock back (${name})`, () => {
      const shown = fold(times);
      const back = shown
        .map((at, index) => ({ frame: times[index]!, at, before: shown[index - 1] ?? 0 }))
        .filter((step) => step.at < step.before);
      expect(back, `the copy's clock at each frame: ${shown.map((at) => at.toFixed(1)).join(", ")}`).toEqual([]);
    });
  }

  test("the frame after a stall early in the fold is one frame on, not most of the way down", () => {
    // What the hold is for (#38481): without it the frame at +97 shows the fold 81 ms in, 95% done.
    const shown = fold(TRACE.slice(0, 3));
    expect(shown[1]!, "the frame before the stall").toBeCloseTo(16, 6);
    expect(shown[2]!, "the frame after the stall").toBeGreaterThanOrEqual(shown[1]!);
    expect(shown[2]!, "the frame after the stall").toBeLessThanOrEqual(shown[1]! + FRAME_MS + 0.001);
  });

  test("a fold with no late frame keeps the page's clock", () => {
    const steady = [16, 33, 50, 66, 83, 100, 116, 133];
    expect(fold(steady)).toEqual(steady.map((at) => at - 16));
  });
});
