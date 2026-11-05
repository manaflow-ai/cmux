// Session Info's Context, open (ContextSection.tsx): the window's parts, whose shares add up to the
// whole window, with usage past the window counted as full and an unknown window as empty.
import { expect, test } from "bun:test";
import { contextParts } from "../src/agent-session/acpmux/session-info/ContextSection";

const sum = (parts: { share: number }[]) => parts.reduce((total, part) => total + part.share, 0);

test("used and free space split the window, and their shares sum to 1", () => {
  const parts = contextParts({ used: 171_500, size: 400_000 });
  expect(parts.map((part) => part.id)).toEqual(["used", "free"]);
  expect(parts[0]!.tokens).toBe(171_500);
  expect(parts[1]!.tokens).toBe(228_500);
  expect(parts[0]!.share).toBeCloseTo(0.42875);
  expect(sum(parts)).toBeCloseTo(1);
});

test("usage past the window is full with no free space; negative usage is none", () => {
  const over = contextParts({ used: 250_000, size: 200_000 });
  expect(over.map((part) => [part.tokens, part.share])).toEqual([
    [200_000, 1],
    [0, 0],
  ]);
  expect(contextParts({ used: -5, size: 100 }).map((part) => part.tokens)).toEqual([0, 100]);
});

test("a window of no size has no shares", () => {
  expect(contextParts({ used: 10, size: 0 }).map((part) => part.share)).toEqual([0, 0]);
});
