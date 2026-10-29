// The DEBUG stream run (`debug.agent_pane action=stream`) wakes the page only for its `seconds`.
// A page that hides mid-run draws no frames (no requestAnimationFrame), so its
// delta feeder must stop on its own deadline, not on the next frame.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "./model";
import { runStream, type StreamSeams } from "./streamDebug";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
/** Frames drawn so far by the browser seams; the page hides once this reaches `framesUntilHidden`. */
let frames = 0;
let framesUntilHidden = Number.POSITIVE_INFINITY;

beforeEach(() => {
  jest.useFakeTimers();
  jest.setSystemTime(1_000_000);
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

/** Frames come only when the test sends them, as on a pane that may hide. */
function fakeSeams() {
  const waiting: ((time: number) => void)[] = [];
  const seams: StreamSeams = {
    frame: () => new Promise<number>((resolve) => waiting.push(resolve)),
    now: () => Date.now(),
    every: (ms, callback) => setInterval(callback, ms),
    cancelEvery: (handle) => clearInterval(handle as ReturnType<typeof setInterval>),
  };
  const sendFrames = async (count: number) => {
    for (let index = 0; index < count; index += 1) {
      while (waiting.length === 0) await Promise.resolve();
      jest.advanceTimersByTime(16);
      waiting.shift()!(Date.now());
    }
  };
  return { seams, sendFrames };
}

test("the feeder stops at the deadline while the pane is hidden", async () => {
  const pushes: AcpmuxRow[][] = [];
  const { seams, sendFrames } = fakeSeams();
  void runStream((rows) => pushes.push(rows), { rows: 3, seconds: 1, chunk_ms: 10 }, seams);
  // The warm-up and the scroll-to-bottom frame, then the feeder starts.
  await sendFrames(31);
  while (jest.getTimerCount() === 0) await Promise.resolve();
  expect(jest.getTimerCount()).toBe(1);

  // Hidden: no more frames. The feeder runs to its deadline and no further.
  jest.advanceTimersByTime(1_000);
  expect(jest.getTimerCount()).toBe(0);
  const last = pushes.at(-1)!.at(-1)!;
  expect(last.id).toBe("debug-stream");
  expect(last.kind === "assistant" && last.streaming).toBe(false);
  const count = pushes.length;
  jest.advanceTimersByTime(60_000);
  expect(pushes.length).toBe(count);
});

async function settle() {
  for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
}

test("a stream run on the browser seams whose page hides mid-run stops feeding deltas at its end", async () => {
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
