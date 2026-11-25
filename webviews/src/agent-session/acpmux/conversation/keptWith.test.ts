// The kept prefix and a tail as one array of exactly their length (prefixFlatMap.ts `keptWith`).
import { expect, test } from "bun:test";
import { keptWith } from "./prefixFlatMap";

test("keptWith is the kept prefix and the tail, whatever their lengths", () => {
  const previous = [1, 2, 3, 4, 5];
  expect(keptWith(previous, 3, [9])).toEqual([1, 2, 3, 9]);
  expect(keptWith(previous, 3, [7, 8])).toEqual([1, 2, 3, 7, 8]);
  expect(keptWith(previous, 3, [6, 7, 8, 9])).toEqual([1, 2, 3, 6, 7, 8, 9]);
  expect(keptWith(previous, 5, [6])).toEqual([1, 2, 3, 4, 5, 6]);
  expect(keptWith(previous, 0, [6])).toEqual([6]);
  expect(keptWith(previous, 2, [])).toEqual([1, 2]);
  // Never more than `previous` holds, as `slice(0, keep)` would.
  expect(keptWith(previous, 9, [6])).toEqual([1, 2, 3, 4, 5, 6]);
  // Items that are arrays stay items.
  expect(keptWith([[1], [2]], 1, [[3]])).toEqual([[1], [3]]);
  // A new array: `previous` is never written.
  const out = keptWith(previous, 3, [9]);
  expect(out).not.toBe(previous);
  expect(previous).toEqual([1, 2, 3, 4, 5]);
});
