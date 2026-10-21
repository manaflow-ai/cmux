import { expect, test } from "bun:test";
import { DataUrlCache } from "../src/agent-session/acpmux/chips/imageCache";

// Reply images keep their loaded data URLs so a row scrolled back into view draws at once. The
// cache must stay bounded: a long session of screenshots used to keep every one for the life of
// the pane.

const dataUrl = (length: number) => `data:image/png;base64,${"A".repeat(length)}`;

test("the cache forgets the least recently drawn image past its count", () => {
  const evicted: string[] = [];
  const cache = new DataUrlCache(3, Number.MAX_SAFE_INTEGER, (src) => evicted.push(src));
  cache.set("a", dataUrl(1));
  cache.set("b", dataUrl(1));
  cache.set("c", dataUrl(1));
  expect(cache.get("a")).toBeDefined(); // "a" is drawn again, so "b" is now the oldest.
  cache.set("d", dataUrl(1));
  expect(evicted).toEqual(["b"]);
  expect(cache.get("b")).toBeUndefined();
  expect(["a", "c", "d"].every((src) => cache.get(src) !== undefined)).toBe(true);
  expect(cache.size).toBe(3);
});

test("the cache stays within its total length", () => {
  const cache = new DataUrlCache(100, 10_000);
  for (let index = 0; index < 50; index++) cache.set(`shot-${index}.png`, dataUrl(3_000));
  expect(cache.totalChars).toBeLessThanOrEqual(10_000);
  expect(cache.size).toBe(3);
  expect(cache.get("shot-49.png")).toBeDefined();
  expect(cache.get("shot-0.png")).toBeUndefined();
});

test("replacing an image counts only its new length", () => {
  const cache = new DataUrlCache(10, 1_000);
  cache.set("a", "x".repeat(600));
  cache.set("a", "y".repeat(300));
  expect(cache.totalChars).toBe(300);
  expect(cache.get("a")).toBe("y".repeat(300));
});

test("the newest image stays even when it alone is over the budget", () => {
  const cache = new DataUrlCache(10, 100);
  cache.set("small", "x".repeat(50));
  cache.set("huge", "y".repeat(500));
  expect(cache.get("huge")).toBeDefined();
  expect(cache.get("small")).toBeUndefined();
  expect(cache.size).toBe(1);
});
