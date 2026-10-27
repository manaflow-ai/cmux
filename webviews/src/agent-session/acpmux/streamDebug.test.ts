// The DEBUG stream run (`debug.agent_pane action=stream`) wakes the page only for its `seconds`
// (p14-energy-062b). A page that hides mid-run draws no frames, so its delta feeder must stop on its
// own end time, not on the next frame.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { runStream } from "./streamDebug";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
/** Frames drawn so far; the page hides once this reaches `framesUntilHidden`. */
let frames = 0;
let framesUntilHidden = Number.POSITIVE_INFINITY;

beforeEach(() => {
  jest.useFakeTimers();
  frames = 0;
  framesUntilHidden = Number.POSITIVE_INFINITY;
  dom = new JSDOM('<!doctype html><html><body><div class="acpmux-scroll"></div></body></html>');
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    // A hidden page draws no frame: its callback never runs.
    requestAnimationFrame: (callback: (time: number) => void) => {
      if (frames >= framesUntilHidden) return 0;
      frames += 1;
      return setTimeout(() => callback(performance.now()), 16);
    },
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
});

afterEach(() => {
  jest.useRealTimers();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
}

test("a stream run whose page hides mid-run stops feeding deltas at its end", async () => {
  // 30 warm-up frames, one after the scroll, then the run's first frame: the page hides there.
  framesUntilHidden = 32;
  let pushes = 0;
  void runStream(() => (pushes += 1), { rows: 3, seconds: 1, chunk_ms: 12 });
  for (let step = 0; step < 100 && frames < framesUntilHidden; step += 1) {
    jest.advanceTimersByTime(16);
    await settle();
  }
  expect(frames).toBe(framesUntilHidden);
  const atHide = pushes;

  jest.advanceTimersByTime(500);
  expect(pushes).toBeGreaterThan(atHide);

  jest.advanceTimersByTime(1_000);
  const atEnd = pushes;
  expect(jest.getTimerCount()).toBe(0);
  jest.advanceTimersByTime(60_000);
  expect(pushes).toBe(atEnd);
});
