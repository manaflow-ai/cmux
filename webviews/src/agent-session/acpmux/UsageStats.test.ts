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
