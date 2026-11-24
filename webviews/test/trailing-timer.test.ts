import { afterEach, expect, jest, test } from "bun:test";
import { trailingTimer } from "../src/ui/trailingTimer";

afterEach(() => jest.useRealTimers());

/// Counts the timers armed and cleared while `run` runs.
function counted(run: () => void) {
  const set = globalThis.setTimeout;
  const clear = globalThis.clearTimeout;
  const calls = { set: 0, clear: 0 };
  globalThis.setTimeout = ((...args: Parameters<typeof setTimeout>) => {
    calls.set += 1;
    return set(...args);
  }) as typeof setTimeout;
  globalThis.clearTimeout = ((id?: Parameters<typeof clearTimeout>[0]) => {
    calls.clear += 1;
    return clear(id);
  }) as typeof clearTimeout;
  try {
    run();
  } finally {
    globalThis.setTimeout = set;
    globalThis.clearTimeout = clear;
  }
  return calls;
}

test("a trailing timer fires once, its delay after the last push", () => {
  jest.useFakeTimers();
  jest.setSystemTime(0);
  let fired = 0;
  const timer = trailingTimer(() => fired++);
  timer.push(120);
  for (let frame = 0; frame < 10; frame += 1) {
    jest.advanceTimersByTime(16);
    timer.push(120);
  }
  // The last push was at 160 ms: nothing before 280.
  jest.advanceTimersByTime(119);
  expect(fired).toBe(0);
  jest.advanceTimersByTime(1);
  expect(fired).toBe(1);
  expect(timer.pending).toBe(false);
  jest.advanceTimersByTime(1000);
  expect(fired).toBe(1);
});

test("a cancelled or stopped trailing timer does not fire", () => {
  jest.useFakeTimers();
  jest.setSystemTime(0);
  let fired = 0;
  const timer = trailingTimer(() => fired++);
  timer.push(50);
  timer.cancel();
  jest.advanceTimersByTime(100);
  expect(fired).toBe(0);
  timer.push(50);
  timer.stop();
  jest.advanceTimersByTime(100);
  expect(fired).toBe(0);
  timer.push(50);
  jest.advanceTimersByTime(50);
  expect(fired).toBe(1);
});

test("pushes a frame for a fling arm one timer per quiet stretch, not one per frame", () => {
  jest.useFakeTimers();
  jest.setSystemTime(0);
  let fired = 0;
  const timer = trailingTimer(() => fired++);
  const calls = counted(() => {
    // 60 frames of a fling, each pushing the rest out by 120 ms.
    for (let frame = 0; frame < 60; frame += 1) {
      timer.push(120);
      jest.advanceTimersByTime(16);
    }
    jest.advanceTimersByTime(200);
  });
  expect(fired).toBe(1);
  // The first arm, and one re-arm each time the timer came early (every 120 ms of the 960 ms fling).
  expect(calls.clear).toBe(0);
  expect(calls.set).toBeLessThanOrEqual(10);
});
