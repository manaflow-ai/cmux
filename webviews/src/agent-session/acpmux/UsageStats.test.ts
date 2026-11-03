import { expect, test } from "bun:test";
import { compactingUsage, type SessionUsageStats } from "./usageStats";

const stats = (over: Partial<SessionUsageStats>): SessionUsageStats => ({
  autocompact: "capped",
  autocompactCap: 400_000,
  updatedAt: 1,
  ...over,
});

test("the context reads against the autocompact window under the model's (Leo: 400K, not 1M)", () => {
  const usage = { used: 213_100, size: 1_000_000 };
  expect(compactingUsage(usage, stats({}))).toEqual({ used: 213_100, size: 400_000 });
});

test("no smaller cap keeps the model's window, the same object", () => {
  const usage = { used: 50_000, size: 200_000, setup: 9_000 };
  expect(compactingUsage(usage, stats({}))).toBe(usage);
  expect(compactingUsage(usage, stats({ autocompact: "none", autocompactCap: undefined }))).toBe(usage);
  expect(compactingUsage(usage, stats({ autocompact: "unknown" }))).toBe(usage);
  expect(compactingUsage(usage, stats({ autocompactCap: undefined }))).toBe(usage);
  expect(compactingUsage(usage, undefined)).toBe(usage);
  expect(compactingUsage(undefined, stats({}))).toBeUndefined();
});

test("the smaller of Claude Code's /context window and acpmux's cap (Leo, 2026-11-02: '/ 400K', not '/ 1M')", () => {
  const usage = { used: 310_600, size: 1_000_000 };
  // No usageStats from acpmux at all: the breakdown alone sets the window.
  expect(compactingUsage(usage, undefined, { maxTokens: 400_000 })).toEqual({ used: 310_600, size: 400_000 });
  // The smaller of the two wins, whichever names it.
  expect(compactingUsage(usage, stats({ autocompactCap: 411_150 }), { maxTokens: 400_000 })).toEqual({
    used: 310_600,
    size: 400_000,
  });
  // A /context window a little under the model's never hides a 400K cap.
  expect(compactingUsage(usage, stats({}), { maxTokens: 980_000 })).toEqual({ used: 310_600, size: 400_000 });
  // A breakdown at the model's window (no setting) falls back to the cap.
  expect(compactingUsage(usage, stats({}), { maxTokens: 1_000_000 })).toEqual({ used: 310_600, size: 400_000 });
  // Nothing smaller: the model's window, the same object.
  expect(compactingUsage(usage, undefined, { maxTokens: 1_000_000 })).toBe(usage);
  expect(compactingUsage(usage, undefined, { maxTokens: "400000" })).toBe(usage);
});
