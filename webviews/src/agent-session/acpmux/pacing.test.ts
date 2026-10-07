import { expect, test } from "bun:test";
import { ScrollPacing, type PacingClock } from "./pacing";

/// A scriptable clock: frames and timers run only when the test advances time.
function fakeClock() {
  let now = 0;
  let nextHandle = 1;
  const frames = new Map<number, (now: number) => void>();
  const timers = new Map<number, { at: number; callback: () => void }>();
  const clock: PacingClock = {
    requestFrame: (callback) => {
      const handle = nextHandle++;
      frames.set(handle, callback);
      return handle;
    },
    cancelFrame: (handle) => {
      frames.delete(handle);
    },
    setTimer: (callback, ms) => {
      const handle = nextHandle++;
      timers.set(handle, { at: now + ms, callback });
      return handle;
    },
    clearTimer: (handle) => {
      timers.delete(handle as number);
    },
  };
  /** Advances by one frame of `interval` ms, running due timers first. */
  const frame = (interval: number) => {
    now += interval;
    for (const [handle, timer] of Array.from(timers))
      if (timer.at <= now) {
        timers.delete(handle);
        timer.callback();
      }
    const pending = [...frames];
    frames.clear();
    for (const [, callback] of pending) callback(now);
  };
  return { clock, frame, pendingFrames: () => frames.size };
}

test("a settled scroll reports its frame intervals once and stops sampling", () => {
  const { clock, frame, pendingFrames } = fakeClock();
  const reports: number[][] = [];
  const pacing = new ScrollPacing((intervals) => reports.push(intervals), clock);
  pacing.scrolled();
  for (const interval of [6, 6, 12, 6]) {
    pacing.scrolled();
    frame(interval);
  }
  expect(reports).toEqual([]);
  for (let index = 0; index < 50 && !reports.length; index += 1) frame(6);
  expect(reports.length).toBe(1);
  expect(reports[0]!.slice(0, 3)).toEqual([6, 12, 6]);
  expect(pendingFrames()).toBe(0);
});

test("a stopped pacing never reports", () => {
  const { clock, frame } = fakeClock();
  const reports: number[][] = [];
  const pacing = new ScrollPacing((intervals) => reports.push(intervals), clock);
  pacing.scrolled();
  frame(6);
  frame(6);
  pacing.stop();
  for (let index = 0; index < 60; index += 1) frame(6);
  expect(reports).toEqual([]);
});
