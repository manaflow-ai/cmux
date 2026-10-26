// The stream bench's delta feeder stops at the bench's deadline even while no frame comes (a hidden
// pane gets no requestAnimationFrame), so a bench left hidden wakes the page for `seconds` at most.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "./model";
import { runStream, type StreamSeams } from "./streamDebug";

const scope = globalThis as Record<string, unknown>;
let saved: unknown;
let dom: JSDOM | undefined;

beforeEach(() => {
  jest.useFakeTimers();
  jest.setSystemTime(1_000_000);
  dom = new JSDOM('<!doctype html><html><body><div class="acpmux-scroll"></div></body></html>');
  saved = scope.document;
  scope.document = dom.window.document;
});

afterEach(() => {
  jest.useRealTimers();
  dom?.window.close();
  dom = undefined;
  if (saved === undefined) delete scope.document;
  else scope.document = saved;
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
