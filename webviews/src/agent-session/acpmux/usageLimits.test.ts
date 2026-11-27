import { expect, test } from "bun:test";
import { planAheadOfPace, planEvenPace } from "./usageLimits";

const NOW = Date.UTC(2026, 10, 23, 12, 0);
const s = NOW / 1000;

test("even pace is the elapsed share of a reported window length", () => {
  // 300-minute window resetting in 3 hours: 2 of 5 hours elapsed.
  expect(planEvenPace({ id: "x", usedPercent: 10, windowMins: 300, resetsAt: s + 3 * 3600 }, NOW)).toBeCloseTo(0.4);
});

test("even pace falls back to Claude's window lengths by id", () => {
  expect(planEvenPace({ id: "session", usedPercent: 10, resetsAt: s + 4 * 3600 }, NOW)).toBeCloseTo(0.2);
  expect(planEvenPace({ id: "weekly", usedPercent: 10, resetsAt: s + 3.5 * 86_400 }, NOW)).toBeCloseTo(0.5);
  expect(planEvenPace({ id: "weekly_opus", usedPercent: 10, resetsAt: s + 7 * 86_400 }, NOW)).toBeCloseTo(0);
  expect(planEvenPace({ id: "weekly_sonnet", usedPercent: 10, resetsAt: s + 86_400 }, NOW)).toBeCloseTo(6 / 7);
});

test("even pace is unset without a reset time or a known length", () => {
  expect(planEvenPace({ id: "session", usedPercent: 10 }, NOW)).toBeUndefined();
  expect(planEvenPace({ id: "monthly", usedPercent: 10, resetsAt: s + 3600 }, NOW)).toBeUndefined();
  expect(planEvenPace({ id: "session", usedPercent: 10, resetsAt: s + 3600 }, Number.NaN)).toBeUndefined();
});

test("even pace clamps to 0..1", () => {
  expect(planEvenPace({ id: "session", usedPercent: 10, resetsAt: s - 60 }, NOW)).toBe(1);
  expect(planEvenPace({ id: "session", usedPercent: 10, resetsAt: s + 10 * 3600 }, NOW)).toBe(0);
});

test("ahead of pace only past the margin", () => {
  const at = (usedPercent: number) => ({ id: "session", usedPercent });
  expect(planAheadOfPace(at(44), 0.4)).toBe(false);
  expect(planAheadOfPace(at(46), 0.4)).toBe(true);
  expect(planAheadOfPace(at(99), undefined)).toBe(false);
});
