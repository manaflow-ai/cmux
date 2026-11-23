import { expect, test } from "bun:test";
import {
  HeightCache,
  HeightIndex,
  anchorAt,
  heightsFor,
  offsetFor,
  rowContentHash,
  windowAt,
} from "./anchoredListModel";

const ids = (n: number, from = 0) => Array.from({ length: n }, (_, i) => `r${from + i}`);
const positions = (list: readonly string[]) => new Map(list.map((id, i) => [id, i]));

test("tops and the row at an offset match a linear walk", () => {
  const heights = Array.from({ length: 1000 }, (_, i) => 20 + ((i * 37) % 90));
  const index = new HeightIndex(heights);
  let top = 0;
  for (let i = 0; i < heights.length; i++) {
    expect(index.top(i)).toBe(top);
    expect(index.indexAt(top)).toBe(i);
    expect(index.indexAt(top + heights[i]! - 0.5)).toBe(i);
    top += heights[i]!;
  }
  expect(index.total()).toBe(top);
  expect(index.indexAt(top + 500)).toBe(999);
  index.set(10, heights[10]! + 50);
  expect(index.top(11)).toBe(heights.slice(0, 11).reduce((a, b) => a + b, 0) + 50);
});

test("a row growing above the view keeps the reader's row where it was", () => {
  const list = ids(100);
  const index = new HeightIndex(list.map(() => 40));
  const anchor = anchorAt(index, list, 2010)!;
  expect(anchor).toEqual({ id: "r50", offset: 10 });
  index.set(3, 240); // a row far above measures 200 px taller
  expect(offsetFor(index, positions(list), anchor, false, 600)).toBe(2210);
});

test("an older page prepended keeps the reader on the same row", () => {
  const list = ids(100, 100);
  const index = new HeightIndex(list.map(() => 40));
  const anchor = anchorAt(index, list, 400)!;
  const grown = [...ids(50, 50), ...list];
  const next = new HeightIndex(
    heightsFor(
      grown.map((id) => ({ id, hash: 0 })),
      new HeightCache(),
      600,
      40,
    ),
  );
  expect(offsetFor(next, positions(grown), anchor, false, 600)).toBe(400 + 50 * 40);
});

test("pinned holds the end whatever grows; unpinned streaming moves nothing", () => {
  const list = ids(30);
  const index = new HeightIndex(list.map(() => 40));
  const pinned = offsetFor(index, positions(list), undefined, true, 600);
  expect(pinned).toBe(30 * 40 - 600);
  index.set(29, 400); // the streaming reply grows
  expect(offsetFor(index, positions(list), undefined, true, 600)).toBe(29 * 40 + 400 - 600);
  const reading = anchorAt(index, list, 200)!;
  index.set(29, 800);
  expect(offsetFor(index, positions(list), reading, false, 600)).toBe(200);
});

test("the mounted window is the viewport and a screen on each side, in O(log n) at 50k rows", () => {
  const index = new HeightIndex(Array.from({ length: 50_000 }, () => 30));
  const { first, last } = windowAt(index, 750_000, 600);
  expect(first).toBe(Math.floor((750_000 - 600) / 30));
  expect(last).toBe(Math.floor((750_000 + 1200) / 30) + 1);
});

test("the height cache is keyed by row id, content hash and width", () => {
  const cache = new HeightCache();
  const closed = rowContentHash(7, false, false);
  const open = rowContentHash(7, true, false);
  const edited = rowContentHash(8, false, false);
  expect(new Set([closed, open, edited, rowContentHash(7, false, true)]).size).toBe(4);

  cache.set("r1", closed, 600, 40);
  cache.set("r1", open, 600, 240);
  cache.set("r1", closed, 400, 64);
  // Each (id, hash, width) keeps its own measurement.
  expect(cache.exact("r1", closed, 600)).toBe(40);
  expect(cache.exact("r1", open, 600)).toBe(240);
  expect(cache.exact("r1", closed, 400)).toBe(64);
  // Another row's id never reads this one's height.
  expect(cache.exact("r2", closed, 600)).toBeUndefined();
  expect(cache.get("r2", closed, 600)).toBeUndefined();
  // New content is not an exact hit; it starts from the row's latest height at that width.
  expect(cache.exact("r1", edited, 600)).toBeUndefined();
  expect(cache.get("r1", edited, 600)).toBe(240);
  // A width it was never drawn at starts from its latest height at any width.
  expect(cache.exact("r1", closed, 800)).toBeUndefined();
  expect(cache.get("r1", closed, 800)).toBe(64);
  // Back at a width and content it was drawn at: exact, without measuring again.
  expect(cache.get("r1", closed, 600)).toBe(40);
  // Measuring the same key again replaces it.
  cache.set("r1", closed, 600, 44);
  expect(cache.exact("r1", closed, 600)).toBe(44);
});

test("the height cache keeps a few measurements per row, newest first", () => {
  const cache = new HeightCache();
  for (let version = 0; version < 10; version++)
    cache.set("r1", rowContentHash(version, false, false), 600, 20 + version);
  expect(cache.exact("r1", rowContentHash(9, false, false), 600)).toBe(29);
  expect(cache.exact("r1", rowContentHash(6, false, false), 600)).toBe(26);
  expect(cache.exact("r1", rowContentHash(5, false, false), 600)).toBeUndefined();
  expect(cache.size).toBe(1);
});

test("heights for the rows come from the cache at the current width", () => {
  const cache = new HeightCache();
  const rows = ids(4).map((id, i) => ({ id, hash: rowContentHash(i, false, false) }));
  cache.set("r0", rows[0]!.hash, 600, 30);
  cache.set("r1", rows[1]!.hash, 600, 50);
  cache.set("r1", rows[1]!.hash, 300, 90);
  expect(heightsFor(rows, cache, 600, 64)).toEqual([30, 50, 64, 64]);
  expect(heightsFor(rows, cache, 300, 64)).toEqual([30, 90, 64, 64]);
  const index = new HeightIndex(heightsFor(rows, cache, 300, 64));
  expect(index.top(2)).toBe(120);
});
