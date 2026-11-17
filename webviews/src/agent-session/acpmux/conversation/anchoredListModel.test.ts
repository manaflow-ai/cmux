import { expect, test } from "bun:test";
import { HeightIndex, anchorAt, heightsFor, offsetFor, windowAt } from "./anchoredListModel";

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
  const next = new HeightIndex(heightsFor(grown, new Map(), 40));
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
