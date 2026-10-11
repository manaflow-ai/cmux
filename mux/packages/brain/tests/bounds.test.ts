import { expect, test } from "bun:test";
import { MAX_AUTHORS, rememberBounded } from "../src/core/core.ts";

// The core's message-author memory (the reply-to-Chief wake rule) is bounded:
// past the cap the oldest entry goes. cmux-chief pins the same rule.
test("rememberBounded keeps the newest entries up to the cap; a known key keeps its place", () => {
  const map = new Map<string, string>();
  rememberBounded(map, "a", "1", 2);
  rememberBounded(map, "b", "2", 2);
  rememberBounded(map, "a", "3", 2);
  rememberBounded(map, "c", "4", 2);
  expect([...map.entries()]).toEqual([
    ["b", "2"],
    ["c", "4"],
  ]);
  expect(MAX_AUTHORS).toBe(10_000);
});
