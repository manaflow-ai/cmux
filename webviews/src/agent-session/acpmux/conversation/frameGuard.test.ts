import { expect, test } from "bun:test";
import { FrameGuard } from "./frameGuard";

/// A frame clock and an observer that delivers each new observation at the frame's end.
function harness(options: { observer?: boolean } = {}) {
  let time = 0;
  let next = 1;
  const frames = new Map<number, () => void>();
  let observed: (() => void) | undefined;
  let watching = false;
  const reads: number[] = [];
  const node = { id: "scroller" } as unknown as Element;
  let present: Element | null = node;
  const guard = new FrameGuard({
    read: () => reads.push(time),
    node: () => present,
    idleMs: 250,
    now: () => time,
    requestFrame: (callback) => {
      frames.set(next, callback);
      return next++;
    },
    cancelFrame: (handle) => frames.delete(handle),
    observer:
      options.observer === false
        ? undefined
        : (callback) => {
            observed = callback;
            return {
              observe: () => (watching = true),
              unobserve: () => (watching = false),
              disconnect: () => {
                watching = false;
                observed = undefined;
              },
            };
          },
  });
  /// One frame of `ms`: its frame callbacks, then the observer phase.
  const frame = (ms = 16) => {
    time += ms;
    const due = [...frames.values()];
    frames.clear();
    for (const callback of due) callback();
    if (watching && observed) {
      watching = false;
      observed();
    }
  };
  return { guard, frame, reads, frames, gone: () => (present = null), at: () => time };
}

test("reads each frame after its callbacks while the offset moves, and stops 250 ms after it stood still", () => {
  const { guard, frame, reads, frames } = harness();
  guard.arm();
  // The arm's own frame is read too (an input that moves the offset in this frame's callbacks).
  frame();
  expect(reads.length).toBe(1);
  for (let at = 0; at < 10; at++) {
    guard.moved();
    frame();
  }
  expect(reads.length).toBe(11);
  // Still from here: it goes on reading until 250 ms have passed since the last move, then asks for no frame.
  const before = reads.length;
  for (let at = 0; at < 30; at++) frame();
  const stillReads = reads.length - before;
  expect(stillReads).toBeGreaterThan(10);
  expect(stillReads).toBeLessThanOrEqual(Math.ceil(250 / 16) + 1);
  expect(guard.pending).toBe(false);
  expect(frames.size).toBe(0);
  const after = reads.length;
  for (let at = 0; at < 30; at++) frame();
  expect(reads.length).toBe(after);
});

test("asks for no frame and reads nothing after stop (the transcript unmounted)", () => {
  const { guard, frame, reads, frames } = harness();
  guard.arm();
  frame();
  guard.moved();
  guard.stop();
  expect(guard.pending).toBe(false);
  expect(frames.size).toBe(0);
  const after = reads.length;
  for (let at = 0; at < 20; at++) frame();
  expect(reads.length).toBe(after);
});

test("stops once the scroller is gone", () => {
  const { guard, frame, frames, gone } = harness();
  guard.arm();
  frame();
  gone();
  guard.moved();
  frame();
  expect(frames.size).toBe(0);
  expect(guard.pending).toBe(false);
});

test("one frame asked for at a time, however often it is armed", () => {
  const { guard, frames } = harness();
  guard.arm();
  guard.arm();
  guard.arm();
  expect(frames.size).toBe(1);
});

test("without an observer it reads in its frame callback", () => {
  const { guard, frame, reads } = harness({ observer: false });
  guard.arm();
  expect(reads.length).toBe(0);
  frame();
  expect(reads.length).toBe(1);
});
