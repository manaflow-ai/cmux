// The first frame after a key draws the key alone (schedule/keyFrame.ts): the stream's frame work
// (`nextFrame`, direct.ts) waits one frame, once, and runs in the frame after; with no key it runs
// in its own frame. Leo, 2026-11-17: "we're not waiting for ui to render. we're just gonna have the
// text be drawn fast".
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { nextFrame } from "./direct";
import { KEY_FRAME_MS, keyFrame, keyInAnotherPage, noteKeyForTest } from "./schedule/keyFrame";

type Frame = (time: number) => void;
let frames: Map<number, Frame>;
let id = 0;
const realRaf = globalThis.requestAnimationFrame;
const realCancel = globalThis.cancelAnimationFrame;

/** Runs the frames asked for so far, at `time`. */
function tick(time: number): void {
  const due = [...frames.values()];
  frames.clear();
  for (const run of due) run(time);
}

beforeEach(() => {
  frames = new Map();
  globalThis.requestAnimationFrame = ((run: Frame) => {
    id += 1;
    frames.set(id, run);
    return id;
  }) as typeof requestAnimationFrame;
  globalThis.cancelAnimationFrame = ((handle: number) => void frames.delete(handle)) as typeof cancelAnimationFrame;
  noteKeyForTest(Number.NEGATIVE_INFINITY);
});

afterEach(() => {
  const host = globalThis as { requestAnimationFrame?: unknown; cancelAnimationFrame?: unknown };
  if (realRaf) globalThis.requestAnimationFrame = realRaf;
  else delete host.requestAnimationFrame;
  if (realCancel) globalThis.cancelAnimationFrame = realCancel;
  else delete host.cancelAnimationFrame;
});

describe("key frame", () => {
  test("a key handled within one display interval before a frame makes it the key's frame", () => {
    noteKeyForTest(100);
    expect(keyFrame(110)).toBe(true);
    expect(keyFrame(100 + KEY_FRAME_MS + 1)).toBe(false);
  });

  test("with no key, the stream draws in its own frame", () => {
    let runs = 0;
    const cancel = nextFrame(() => (runs += 1));
    tick(1000);
    expect(runs).toBe(1);
    cancel();
  });

  test("a key's frame draws the key alone; the stream draws in the next frame", () => {
    let runs = 0;
    const cancel = nextFrame(() => (runs += 1));
    noteKeyForTest(995);
    tick(1000);
    expect(runs).toBe(0);
    tick(1016);
    expect(runs).toBe(1);
    cancel();
  });

  test("the stream waits once: a key in every frame never starves it", () => {
    let runs = 0;
    const cancel = nextFrame(() => (runs += 1));
    noteKeyForTest(995);
    tick(1000);
    noteKeyForTest(1010);
    tick(1016);
    expect(runs).toBe(1);
    cancel();
  });

  test("a key typed in another chat page of the renderer keeps this page's stream out of that frame", () => {
    let runs = 0;
    const cancel = nextFrame(() => (runs += 1));
    keyInAnotherPage();
    tick(performance.now() + 1);
    expect(runs).toBe(0);
    tick(performance.now() + 18);
    expect(runs).toBe(1);
    cancel();
  });

  test("a cancelled wait runs nothing, also after it yielded to a key", () => {
    let runs = 0;
    const cancel = nextFrame(() => (runs += 1));
    noteKeyForTest(995);
    tick(1000);
    cancel();
    tick(1016);
    expect(runs).toBe(0);
    expect(frames.size).toBe(0);
  });
});
