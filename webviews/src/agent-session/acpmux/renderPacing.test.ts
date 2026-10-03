import { expect, test } from "bun:test";
import { AdaptiveRenderRate, reportScrollPacing } from "./renderPacing";

const scroll = (fast: number, late = 0, slow = 0, frames = 120) =>
  Array.from({ length: frames }, (_, index) => (index % 10 < late ? slow : fast));
const start = 1_000;
const display = 6.25;
const backoff = AdaptiveRenderRate.firstBackoff;

test("a smooth scroll stays at full rate", () => {
  const policy = new AdaptiveRenderRate();
  expect(policy.record(scroll(display, 1, 8), display, start)).toBeUndefined();
  expect(policy.isFullRate).toBe(true);
});

test("a scroll that misses frames drops to the capped rate", () => {
  const policy = new AdaptiveRenderRate();
  expect(policy.record(scroll(display, 4, 12.5), display, start)).toBe(false);
  expect(policy.isFullRate).toBe(false);
});

test("a short scroll decides nothing", () => {
  const policy = new AdaptiveRenderRate();
  expect(policy.record(scroll(12.5, 0, 0, AdaptiveRenderRate.minimumFrames - 1), display, start)).toBeUndefined();
});

test("a clean capped scroll restores full rate after the backoff", () => {
  const policy = new AdaptiveRenderRate();
  policy.record(scroll(12.5), display, start);
  expect(policy.record(scroll(12.5), display, start + backoff / 2)).toBeUndefined();
  expect(policy.record(scroll(12.5), display, start + backoff + 1)).toBe(true);
});

test("a capped scroll that still misses frames keeps the cap", () => {
  const policy = new AdaptiveRenderRate();
  policy.record(scroll(12.5), display, start);
  expect(policy.record(scroll(12.5, 3, 25), display, start + backoff + 1)).toBeUndefined();
  expect(policy.isFullRate).toBe(false);
});

test("a quick relapse doubles the backoff", () => {
  const policy = new AdaptiveRenderRate();
  policy.record(scroll(12.5), display, start);
  const restored = start + backoff + 1;
  expect(policy.record(scroll(12.5), display, restored)).toBe(true);
  const relapse = restored + 2;
  expect(policy.record(scroll(12.5), display, relapse)).toBe(false);
  expect(policy.record(scroll(12.5), display, relapse + backoff + 1)).toBeUndefined();
  expect(policy.record(scroll(12.5), display, relapse + 2 * backoff + 1)).toBe(true);
});

test("a display near sixty hertz stays at its rate", () => {
  const policy = new AdaptiveRenderRate();
  expect(policy.record(scroll(33.3), 1000 / 60, start)).toBeUndefined();
  expect(policy.isFullRate).toBe(true);
});

test("a non-adaptive host never receives a render-rate update", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const policy = new AdaptiveRenderRate();
  await reportScrollPacing(scroll(display, 4, 12.5), async <T>(method, params) => {
    calls.push([method, params]);
    return { adaptive: false, displayInterval: display } as T;
  }, policy, () => start);
  expect(calls).toEqual([["pane.framePacing", { intervals: scroll(display, 4, 12.5) }]]);
});

test("a changed decision is sent through the existing bridge", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const policy = new AdaptiveRenderRate();
  await reportScrollPacing(scroll(display, 4, 12.5), async <T>(method, params) => {
    calls.push([method, params]);
    return { adaptive: true, displayInterval: display } as T;
  }, policy, () => start);
  expect(calls[1]).toEqual(["pane.renderRate", { full: false }]);
});
