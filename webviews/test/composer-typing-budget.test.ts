// The composer typing budgets read on the harness's display (bench/composer-load.ts displayBudgets).
import { expect, test } from "bun:test";
import { APP_DISPLAY_HZ, displayBudgets, displayRefreshMs } from "../bench/composer-load";

test("the app's budgets hold on its own 120 Hz display and gain the longer refresh's wait at 60 Hz", () => {
  expect(APP_DISPLAY_HZ).toBe(120);
  expect(displayBudgets(1000 / 120)).toEqual({ p95: 16, p99: 33 });
  expect(displayBudgets(1000 / 60)).toEqual({ p95: 24.33, p99: 41.33 });
  // A display as fast as the app's, or faster, never gets a looser budget than the app's.
  expect(displayBudgets(1000 / 240)).toEqual({ p95: 16, p99: 33 });
  expect(displayBudgets(Number.NaN)).toEqual({ p95: 16, p99: 33 });
});

test("a page's display refresh is its fastest frame intervals, not its dropped frames", () => {
  // A 60 Hz page that dropped a third of its frames still refreshes every 16.7 ms.
  const intervals = Array.from({ length: 300 }, (_, i) => (i % 3 === 0 ? 33.33 : 16.67));
  expect(displayRefreshMs(intervals)).toBeCloseTo(16.67, 2);
  expect(displayRefreshMs(Array.from({ length: 300 }, () => 8.33))).toBeCloseTo(8.33, 2);
  // Too few frames to tell: Chromium's own 60 Hz.
  expect(displayRefreshMs([8.33])).toBeCloseTo(1000 / 60, 2);
});
